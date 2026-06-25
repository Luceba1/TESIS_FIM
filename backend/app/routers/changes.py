import csv
import io
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import ChangeReviewStatus, Environment, EventType, FileChange, ScanRun, utc_now
from app.schemas import FileChangeRead
from app.services.notifier import retry_change_webhook

router = APIRouter(prefix="/changes", tags=["Eventos detectados"])


def as_utc(dt: datetime | None) -> datetime | None:
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def seconds_between(end: datetime | None, start: datetime | None) -> float | None:
    end_utc = as_utc(end)
    start_utc = as_utc(start)
    if not end_utc or not start_utc:
        return None
    return max(0.0, (end_utc - start_utc).total_seconds())


def change_to_read(session: Session, change: FileChange) -> FileChangeRead:
    env = session.get(Environment, change.environment_id)
    scan_run = session.get(ScanRun, change.scan_run_id)
    return FileChangeRead(
        **change.model_dump(),
        environment_name=env.name if env else "Entorno desconocido",
        environment_criticality=env.criticality.value if env else "",
        detection_time_seconds=seconds_between(change.detected_at, scan_run.started_at if scan_run else None),
        response_time_seconds=seconds_between(change.reviewed_at, change.detected_at),
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


@router.get("/export")
def export_changes_csv(
    environment_id: int | None = None,
    event_type: EventType | None = None,
    review_status: ChangeReviewStatus | None = None,
    session: Session = Depends(get_session),
):
    """Exporta eventos de integridad en formato CSV para evidencia/anexos."""
    stmt = select(FileChange)
    if environment_id is not None:
        stmt = stmt.where(FileChange.environment_id == environment_id)
    if event_type:
        stmt = stmt.where(FileChange.event_type == event_type)
    if review_status:
        stmt = stmt.where(FileChange.review_status == review_status)

    changes = session.exec(stmt.order_by(FileChange.detected_at.desc())).all()

    output = io.StringIO()
    writer = csv.writer(output, delimiter=";")
    writer.writerow([
        "id",
        "entorno",
        "criticidad_entorno",
        "evento",
        "archivo",
        "ruta_completa",
        "sha256_anterior",
        "sha256_nuevo",
        "md5_anterior",
        "md5_nuevo",
        "tamano_bytes",
        "detectado_en",
        "revisado_en",
        "mttd_segundos",
        "mttr_segundos",
        "estado_revision",
        "scan_run_id",
        "webhook_estado",
        "webhook_error",
    ])

    for change in changes:
        env = session.get(Environment, change.environment_id)
        filename = change.path.replace("\\", "/").split("/")[-1]
        writer.writerow([
            change.id,
            env.name if env else "Entorno desconocido",
            env.criticality.value if env else "",
            change.event_type.value,
            filename,
            change.path,
            change.old_sha256,
            change.new_sha256,
            change.old_md5,
            change.new_md5,
            change.size_bytes,
            change.detected_at.isoformat(),
            change.reviewed_at.isoformat() if change.reviewed_at else "",
            seconds_between(change.detected_at, session.get(ScanRun, change.scan_run_id).started_at if session.get(ScanRun, change.scan_run_id) else None),
            seconds_between(change.reviewed_at, change.detected_at),
            change.review_status.value,
            change.scan_run_id,
            change.webhook_status.value,
            change.webhook_error,
        ])

    filename = f"watchdogs_fim_evidencia_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    return Response(
        content="\ufeff" + output.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.patch("/{change_id}/review", response_model=FileChangeRead)
def review_change(change_id: int, status: ChangeReviewStatus, session: Session = Depends(get_session)):
    change = session.get(FileChange, change_id)
    if not change:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    change.review_status = status
    if status == ChangeReviewStatus.PENDING:
        change.reviewed_at = None
    else:
        change.reviewed_at = utc_now()
    session.add(change)
    session.commit()
    session.refresh(change)
    return change_to_read(session, change)


@router.post("/{change_id}/webhook/retry", response_model=FileChangeRead)
def retry_change_webhook_route(change_id: int, session: Session = Depends(get_session)):
    change = retry_change_webhook(session, change_id)
    if not change:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    return change_to_read(session, change)
