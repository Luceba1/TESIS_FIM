from datetime import datetime, time, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, func, select

from app.core.db import get_session
from app.models import ChangeReviewStatus, Environment, FileChange, FileHash, FileStatus, MonitoredPath
from app.schemas import EnvironmentCreate, EnvironmentRead, EnvironmentUpdate

router = APIRouter(prefix="/environments", tags=["Entornos controlados"])


def today_start() -> datetime:
    return datetime.combine(datetime.now(timezone.utc).date(), time.min, tzinfo=timezone.utc)


def environment_to_read(session: Session, env: Environment) -> EnvironmentRead:
    paths_count = session.exec(
        select(func.count()).select_from(MonitoredPath).where(MonitoredPath.environment_id == env.id)
    ).one() or 0
    active_files = session.exec(
        select(func.count()).select_from(FileHash).where(
            FileHash.environment_id == env.id,
            FileHash.status == FileStatus.ACTIVE,
        )
    ).one() or 0
    events_today = session.exec(
        select(func.count()).select_from(FileChange).where(
            FileChange.environment_id == env.id,
            FileChange.detected_at >= today_start(),
        )
    ).one() or 0
    pending_events = session.exec(
        select(func.count()).select_from(FileChange).where(
            FileChange.environment_id == env.id,
            FileChange.review_status == ChangeReviewStatus.PENDING,
        )
    ).one() or 0
    return EnvironmentRead(
        **env.model_dump(),
        paths_count=paths_count,
        active_files=active_files,
        events_today=events_today,
        pending_events=pending_events,
    )


@router.get("", response_model=list[EnvironmentRead])
def list_environments(session: Session = Depends(get_session)):
    envs = session.exec(select(Environment).order_by(Environment.created_at.desc())).all()
    return [environment_to_read(session, env) for env in envs]


@router.post("", response_model=EnvironmentRead)
def create_environment(payload: EnvironmentCreate, session: Session = Depends(get_session)):
    existing = session.exec(select(Environment).where(Environment.name == payload.name)).first()
    if existing:
        raise HTTPException(status_code=409, detail="Ya existe un entorno con ese nombre")

    env = Environment(**payload.model_dump())
    session.add(env)
    session.commit()
    session.refresh(env)
    return environment_to_read(session, env)


@router.patch("/{environment_id}", response_model=EnvironmentRead)
def update_environment(environment_id: int, payload: EnvironmentUpdate, session: Session = Depends(get_session)):
    env = session.get(Environment, environment_id)
    if not env:
        raise HTTPException(status_code=404, detail="Entorno no encontrado")

    if payload.name and payload.name != env.name:
        existing = session.exec(select(Environment).where(Environment.name == payload.name)).first()
        if existing:
            raise HTTPException(status_code=409, detail="Ya existe un entorno con ese nombre")

    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(env, key, value)

    session.add(env)
    session.commit()
    session.refresh(env)
    return environment_to_read(session, env)
