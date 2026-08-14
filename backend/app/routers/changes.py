import csv
import io
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlmodel import Session, select

from app.core.db import get_session
from app.core.time_utils import as_utc, iso_utc, seconds_between
from app.models import ChangeReviewStatus, Environment, EventType, FileChange, ScanRun, utc_now
from app.schemas import EventTimeUpdate, FileChangeRead
from app.services.notifier import retry_change_webhook

router = APIRouter(prefix="/changes", tags=["Eventos detectados"])


def change_to_read(session: Session, change: FileChange) -> FileChangeRead:
    env = session.get(Environment, change.environment_id)
    scan_run = session.get(ScanRun, change.scan_run_id)
    data = change.model_dump()
    # La API expone las marcas del experimento siempre en UTC y con offset, aun
    # cuando PostgreSQL utilice otra zona horaria de sesión para representarlas.
    data["occurred_at"] = as_utc(change.occurred_at)
    data["detected_at"] = as_utc(change.detected_at)
    data["reviewed_at"] = as_utc(change.reviewed_at)
    return FileChangeRead(
        **data,
        environment_name=env.name if env else "Entorno desconocido",
        environment_criticality=env.criticality.value if env else "",
        detection_time_seconds=seconds_between(change.detected_at, change.occurred_at),
        scan_processing_time_seconds=seconds_between(
            change.detected_at,
            scan_run.started_at if scan_run else None,
        ),
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
    """Exporta eventos con marcas suficientes para reproducir MTTD/MTTR."""
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
        "ocurrido_en",
        "fuente_tiempo_evento",
        "detectado_en",
        "revisado_en",
        "mttd_segundos",
        "latencia_escaneo_segundos",
        "mttr_segundos",
        "baseline_sha256",
        "baseline_md5",
        "coincide_baseline",
        "sha256_anterior_observado",
        "sha256_nuevo_observado",
        "md5_anterior_observado",
        "md5_nuevo_observado",
        "tamano_bytes",
        "estado_revision",
        "scan_run_id",
        "webhook_estado",
        "webhook_error",
    ])

    for change in changes:
        env = session.get(Environment, change.environment_id)
        scan_run = session.get(ScanRun, change.scan_run_id)
        filename = change.path.replace("\\", "/").split("/")[-1]
        writer.writerow([
            change.id,
            env.name if env else "Entorno desconocido",
            env.criticality.value if env else "",
            change.event_type.value,
            filename,
            change.path,
            iso_utc(change.occurred_at) or "",
            change.occurred_at_source,
            iso_utc(change.detected_at) or "",
            iso_utc(change.reviewed_at) or "",
            seconds_between(change.detected_at, change.occurred_at),
            seconds_between(change.detected_at, scan_run.started_at if scan_run else None),
            seconds_between(change.reviewed_at, change.detected_at),
            change.baseline_sha256,
            change.baseline_md5,
            "" if change.baseline_match is None else str(change.baseline_match).lower(),
            change.old_sha256,
            change.new_sha256,
            change.old_md5,
            change.new_md5,
            change.size_bytes,
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


@router.patch("/{change_id}/event-time", response_model=FileChangeRead)
def set_event_time(change_id: int, payload: EventTimeUpdate, session: Session = Depends(get_session)):
    """Asocia una marca temporal controlada al evento para medición experimental.

    Es especialmente útil para DELETED, cuyo instante de ocurrencia no puede
    reconstruirse a posteriori mediante un escáner periódico.
    """
    change = session.get(FileChange, change_id)
    if not change:
        raise HTTPException(status_code=404, detail="Evento no encontrado")

    source = payload.source.strip().upper() or "EXPERIMENT_CONTROLLED"
    change.occurred_at = as_utc(payload.occurred_at)
    change.occurred_at_source = source[:80]
    session.add(change)
    session.commit()
    session.refresh(change)
    return change_to_read(session, change)


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
