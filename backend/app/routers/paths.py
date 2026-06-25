from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import Environment, MonitoredPath
from app.schemas import MonitoredPathCreate, MonitoredPathRead, MonitoredPathUpdate

router = APIRouter(prefix="/paths", tags=["Rutas monitoreadas"])


@router.get("", response_model=list[MonitoredPathRead])
def list_paths(environment_id: int | None = None, session: Session = Depends(get_session)):
    query = select(MonitoredPath).order_by(MonitoredPath.created_at.desc())
    if environment_id is not None:
        query = query.where(MonitoredPath.environment_id == environment_id)
    return session.exec(query).all()


@router.post("", response_model=MonitoredPathRead)
def create_path(payload: MonitoredPathCreate, session: Session = Depends(get_session)):
    env = session.get(Environment, payload.environment_id)
    if not env:
        raise HTTPException(status_code=404, detail="Entorno no encontrado")

    existing = session.exec(select(MonitoredPath).where(MonitoredPath.path == payload.path)).first()
    if existing:
        raise HTTPException(status_code=409, detail="La ruta ya está registrada")

    monitored = MonitoredPath(**payload.model_dump())
    session.add(monitored)
    session.commit()
    session.refresh(monitored)
    return monitored


@router.patch("/{path_id}", response_model=MonitoredPathRead)
def update_path(path_id: int, payload: MonitoredPathUpdate, session: Session = Depends(get_session)):
    monitored = session.get(MonitoredPath, path_id)
    if not monitored:
        raise HTTPException(status_code=404, detail="Ruta no encontrada")

    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(monitored, key, value)

    session.add(monitored)
    session.commit()
    session.refresh(monitored)
    return monitored
