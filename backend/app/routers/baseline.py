from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import FileHash
from app.schemas import FileHashRead
from app.services.fim_service import generate_baseline

router = APIRouter(prefix="/baseline", tags=["Línea base"])


@router.post("/generate")
def generate(
    monitored_path_id: int | None = None,
    environment_id: int | None = None,
    session: Session = Depends(get_session),
):
    return generate_baseline(session, monitored_path_id=monitored_path_id, environment_id=environment_id)


@router.get("", response_model=list[FileHashRead])
def list_baseline(environment_id: int | None = None, session: Session = Depends(get_session)):
    query = select(FileHash).order_by(FileHash.updated_at.desc())
    if environment_id is not None:
        query = query.where(FileHash.environment_id == environment_id)
    return session.exec(query).all()
