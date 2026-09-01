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

    # La tarjeta "Archivos activos / En línea base" debe contar exclusivamente
    # archivos activos cuya referencia haya sido aprobada explícitamente. Un
    # CREATED recién observado permanece ACTIVE, pero no pertenece todavía a la
    # baseline hasta que el operador lo aprueba.
    active_files = count(
        session,
        select(func.count())
        .select_from(FileHash)
        .where(
            FileHash.status == FileStatus.ACTIVE,
            FileHash.baseline_approved == True,  # noqa: E712
        ),
    )

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

    # MTTD operativo: no se mezclan silenciosamente referencias temporales de
    # distinto constructo. FILE_MTIME es la referencia preferida para el panel
    # operativo. Si la base contiene una única fuente distinta (por ejemplo un
    # entorno exclusivamente experimental), se informa esa fuente sin mezclarla.
    detection_rows = session.exec(
        select(FileChange.detected_at, FileChange.occurred_at, FileChange.occurred_at_source)
    ).all()
    mttd_by_source: dict[str, list[float]] = {}
    mttd_missing_count = 0
    for detected_at, occurred_at, occurred_at_source in detection_rows:
        value = seconds_between(detected_at, occurred_at)
        if value is None:
            mttd_missing_count += 1
            continue
        source = (occurred_at_source or "UNKNOWN").strip().upper()
        mttd_by_source.setdefault(source, []).append(value)

    if "FILE_MTIME" in mttd_by_source:
        selected_mttd_source: str | None = "FILE_MTIME"
    elif len(mttd_by_source) == 1:
        selected_mttd_source = next(iter(mttd_by_source))
    else:
        selected_mttd_source = None

    selected_mttd_values = mttd_by_source.get(selected_mttd_source, []) if selected_mttd_source else []
    excluded_source_count = sum(
        len(values)
        for source, values in mttd_by_source.items()
        if source != selected_mttd_source
    )
    mttd_by_source_summary = {
        source: {
            "average_seconds": average(values),
            "sample_count": len(values),
        }
        for source, values in sorted(mttd_by_source.items())
    }

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

    last_scan_status = None
    if last_scan:
        last_scan_status = last_scan.status.value
        # El dashboard ya muestra last_scan_status debajo de "Escaneos hoy";
        # incluir el contador aquí hace visible un PARTIAL con archivos omitidos
        # sin ocultar la degradación operativa al usuario.
        if last_scan.files_skipped:
            last_scan_status = f"{last_scan_status} · omitidos={last_scan.files_skipped}"

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
        "last_scan_status": last_scan_status,
        "last_scan_files_checked": last_scan.files_checked if last_scan else 0,
        "last_scan_files_skipped": last_scan.files_skipped if last_scan else 0,
        "agent_last_seen_at": heartbeat.last_seen_at if heartbeat else None,
        "average_mttd_seconds": average(selected_mttd_values),
        "mttd_source": selected_mttd_source,
        "mttd_by_source": mttd_by_source_summary,
        "average_scan_processing_seconds": average([value for value in processing_values if value is not None]),
        "average_mttr_seconds": average([value for value in mttr_values if value is not None]),
        "mttd_sample_count": len(selected_mttd_values),
        "mttd_missing_count": mttd_missing_count,
        "mttd_excluded_source_count": excluded_source_count,
    }
