from datetime import datetime, time, timezone

from sqlmodel import Session, func, select

from app.models import (
    AgentHeartbeat,
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


def get_metrics(session: Session) -> dict:
    today_start = datetime.combine(datetime.now(timezone.utc).date(), time.min, tzinfo=timezone.utc)

    environments = count(session, select(func.count()).select_from(Environment))
    monitored_paths = count(session, select(func.count()).select_from(MonitoredPath))
    active_files = count(session, select(func.count()).select_from(FileHash).where(FileHash.status == FileStatus.ACTIVE))
    events_today = count(session, select(func.count()).select_from(FileChange).where(FileChange.detected_at >= today_start))
    pending_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == "PENDING"))
    reviewed_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == "REVIEWED"))
    ignored_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == "IGNORED"))
    false_positive_events = count(session, select(func.count()).select_from(FileChange).where(FileChange.review_status == "FALSE_POSITIVE"))
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
    }
