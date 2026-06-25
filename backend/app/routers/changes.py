from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import ChangeReviewStatus, Environment, EventType, FileChange
from app.schemas import FileChangeRead

router = APIRouter(prefix="/changes", tags=["Eventos detectados"])


def change_to_read(session: Session, change: FileChange) -> FileChangeRead:
    env = session.get(Environment, change.environment_id)
    return FileChangeRead(
        **change.model_dump(),
        environment_name=env.name if env else "Entorno desconocido",
        environment_criticality=env.criticality.value if env else "",
    )


@router.get("", response_model=list[FileChangeRead])
def list_changes(
    environment_id: int | None = None,
    event_type: EventType | None = None,
    review_status: ChangeReviewStatus | None = None,
    session: Session = Depends(get_session),
):
    stmt = select(FileChange)
    if environment_id is not None:
        stmt = stmt.where(FileChange.environment_id == environment_id)
    if event_type:
        stmt = stmt.where(FileChange.event_type == event_type)
    if review_status:
        stmt = stmt.where(FileChange.review_status == review_status)

    changes = session.exec(stmt.order_by(FileChange.detected_at.desc()).limit(200)).all()
    return [change_to_read(session, change) for change in changes]


@router.patch("/{change_id}/review", response_model=FileChangeRead)
def review_change(change_id: int, status: ChangeReviewStatus, session: Session = Depends(get_session)):
    change = session.get(FileChange, change_id)
    if not change:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    change.review_status = status
    session.add(change)
    session.commit()
    session.refresh(change)
    return change_to_read(session, change)
