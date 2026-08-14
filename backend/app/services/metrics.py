from datetime import datetime, time, timezone

from sqlmodel import Session, func, select

from app.core.time_utils import seconds_between
from app.models import (
    AgentHeartbeat,
    ChangeReviewStatus,
    Criticality,
    Environment,
    EventType,
    FileChange,
    FileHash,
    FileStatus,
    MonitoredPath,
    ScanRun,
)


def count(session: Session, stmt) -> int:
    return session.exec(stmt).one() or 0


def average(values: list[float]) -> float | None:
    clean_values = [value for value in values if value is not None]
    if not clean_values:
        return None
    return round(sum(clean_values) / len(clean_values), 2)


def get_metrics(session: Session) -> dict:
    today_start = datetime.combine(datetime.now(timezone.utc).date(), time.min, tzinfo=timezone.utc)

    environments = count(session, select(func.count()).select_from(Environment))
    monitored_paths = count(session, select(func.count()).select_from(MonitoredPath))
    active_files = count(session, select(func.count()).select_from(FileHash).where(FileHash.status == FileStatus.ACTIVE))
    events_today = count(session, select(func.count()).select_from(FileChange).where(FileChange.detected_at >= today_start))
    pending_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == ChangeReviewStatus.PENDING))
    reviewed_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == ChangeReviewStatus.REVIEWED))
    ignored_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == ChangeReviewStatus.IGNORED))
    false_positive_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == ChangeReviewStatus.FALSE_POSITIVE))
    scans_today = count(session, select(func.count()).select_from(ScanRun).where(ScanRun.started_at >= today_start))
    created_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.event_type == EventType.CREATED))
    modified_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.event_type == EventType.MODIFIED))
    deleted_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.event_type == EventType.DELETED))
    critical_events_today = count(
        session,
        select(func.count())
        .select_from(FileChange)
        .join(Environment, Environment.id == FileChange.environment_id)
        .where(
            FileChange.detected_at >= today_start,
            Environment.criticality == Criticality.CRITICAL,
        ),
    )

    last_scan = session.exec(select(ScanRun).order_by(ScanRun.started_at.desc())).first()
    heartbeat = session.exec(select(AgentHeartbeat).order_by(AgentHeartbeat.last_seen_at.desc())).first()

    # MTTD: tiempo entre la referencia temporal del cambio y su detección.
    # Los eventos sin occurred_at (por ejemplo DELETED sin marca experimental)
    # no se mezclan silenciosamente en el promedio.
    detection_rows = session.exec(
        select(FileChange.detected_at, FileChange.occurred_at)
    ).all()
    mttd_values = [seconds_between(detected_at, occurred_at) for detected_at, occurred_at in detection_rows]
    mttd_clean = [value for value in mttd_values if value is not None]

    # Latencia interna del escaneo: métrica separada del MTTD.
    processing_rows = session.exec(
        select(FileChange.detected_at, ScanRun.started_at)
        .join(ScanRun, ScanRun.id == FileChange.scan_run_id)
        .where(ScanRun.started_at.is_not(None))
    ).all()
    processing_values = [seconds_between(detected_at, started_at) for detected_at, started_at in processing_rows]

    # MTTR: tiempo entre detección y primera acción de revisión documentada.
    response_rows = session.exec(
        select(FileChange.detected_at, FileChange.reviewed_at)
        .where(
            FileChange.reviewed_at.is_not(None),
            FileChange.review_status != ChangeReviewStatus.PENDING,
        )
    ).all()
    mttr_values = [seconds_between(reviewed_at, detected_at) for detected_at, reviewed_at in response_rows]

    return {
        "environments": environments,
        "monitored_paths": monitored_paths,
        "active_files": active_files,
        "events_today": events_today,
        "pending_events": pending_events,
        "reviewed_events": reviewed_events,
        "ignored_events": ignored_events,
        "false_positive_events": false_positive_events,
        "scans_today": scans_today,
        "created_events": created_events,
        "modified_events": modified_events,
        "deleted_events": deleted_events,
        "critical_events_today": critical_events_today,
        "last_scan_at": last_scan.finished_at if last_scan else None,
        "last_scan_status": last_scan.status.value if last_scan else None,
        "agent_last_seen_at": heartbeat.last_seen_at if heartbeat else None,
        "average_mttd_seconds": average(mttd_clean),
        "average_scan_processing_seconds": average([value for value in processing_values if value is not None]),
        "average_mttr_seconds": average([value for value in mttr_values if value is not None]),
        "mttd_sample_count": len(mttd_clean),
        "mttd_missing_count": len(mttd_values) - len(mttd_clean),
    }
