from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import FileHash
from app.schemas import FileHashRead
from app.services.fim_service import approve_current_state, generate_baseline

router = APIRouter(prefix="/baseline", tags=["Línea base"])


@router.post("/generate")
def generate(
    monitored_path_id: int | None = None,
    environment_id: int | None = None,
    session: Session = Depends(get_session),
):
    return generate_baseline(session, monitored_path_id=monitored_path_id, environment_id=environment_id)


@router.post("/{file_hash_id}/approve-current", response_model=FileHashRead)
def approve_current(file_hash_id: int, session: Session = Depends(get_session)):
    try:
        file_hash = approve_current_state(session, file_hash_id)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if not file_hash:
        raise HTTPException(status_code=404, detail="Archivo de línea base no encontrado")
    return file_hash


@router.get("", response_model=list[FileHashRead])
def list_baseline(environment_id: int | None = None, session: Session = Depends(get_session)):
    query = select(FileHash).order_by(FileHash.updated_at.desc())
    if environment_id is not None:
        query = query.where(FileHash.environment_id == environment_id)
    return session.exec(query).all()
