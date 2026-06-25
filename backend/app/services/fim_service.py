from datetime import datetime, timezone
from pathlib import Path

from sqlmodel import Session, select

from app.models import (
    Environment,
    EventType,
    FileChange,
    FileHash,
    FileStatus,
    MonitoredPath,
    ScanRun,
    ScanStatus,
    WebhookStatus,
)
from app.services.hashing import calculate_hashes
from app.services.notifier import notify_change


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iter_files(root: Path, recursive: bool = True) -> list[Path]:
    if not root.exists() or not root.is_dir():
        raise ValueError(f"La ruta no existe o no es una carpeta: {root}")

    iterator = root.rglob("*") if recursive else root.glob("*")
    return [item for item in iterator if item.is_file()]


def file_metadata(path: Path) -> tuple[str, str, int, datetime]:
    sha256, md5 = calculate_hashes(path)
    stat = path.stat()
    last_modified = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
    return sha256, md5, stat.st_size, last_modified


def enabled_paths_query(environment_id: int | None = None):
    query = (
        select(MonitoredPath, Environment)
        .join(Environment, Environment.id == MonitoredPath.environment_id)
        .where(MonitoredPath.enabled == True, Environment.enabled == True)  # noqa: E712
    )
    if environment_id is not None:
        query = query.where(Environment.id == environment_id)
    return query


def generate_baseline(session: Session, monitored_path_id: int | None = None, environment_id: int | None = None) -> dict:
    query = enabled_paths_query(environment_id)
    if monitored_path_id is not None:
        query = query.where(MonitoredPath.id == monitored_path_id)

    rows = session.exec(query).all()
    files_count = 0

    for monitored, environment in rows:
        root = Path(monitored.path)
        for file_path in iter_files(root, monitored.recursive):
            sha256, md5, size_bytes, last_modified = file_metadata(file_path)
            normalized_path = str(file_path.resolve())

            existing = session.exec(select(FileHash).where(FileHash.path == normalized_path)).first()
            if existing:
                existing.environment_id = environment.id
                existing.monitored_path_id = monitored.id
                existing.sha256 = sha256
                existing.md5 = md5
                existing.size_bytes = size_bytes
                existing.last_modified = last_modified
                existing.status = FileStatus.ACTIVE
                existing.updated_at = utc_now()
                session.add(existing)
            else:
                session.add(
                    FileHash(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        path=normalized_path,
                        sha256=sha256,
                        md5=md5,
                        size_bytes=size_bytes,
                        last_modified=last_modified,
                        status=FileStatus.ACTIVE,
                    )
                )
            files_count += 1

    session.commit()
    environments_processed = len({environment.id for _, environment in rows})
    return {
        "environments_processed": environments_processed,
        "paths_processed": len(rows),
        "files_registered": files_count,
    }


def run_scan(session: Session, environment_id: int | None = None) -> ScanRun:
    scan = ScanRun(status=ScanStatus.RUNNING, started_at=utc_now(), environment_id=environment_id)
    session.add(scan)
    session.commit()
    session.refresh(scan)

    detected_changes: list[FileChange] = []
    files_checked = 0

    try:
        rows = session.exec(enabled_paths_query(environment_id)).all()

        for monitored, environment in rows:
            root = Path(monitored.path)
            current_paths: set[str] = set()

            for file_path in iter_files(root, monitored.recursive):
                normalized_path = str(file_path.resolve())
                current_paths.add(normalized_path)
                files_checked += 1

                sha256, md5, size_bytes, last_modified = file_metadata(file_path)
                existing = session.exec(select(FileHash).where(FileHash.path == normalized_path)).first()

                if existing is None:
                    file_hash = FileHash(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        path=normalized_path,
                        sha256=sha256,
                        md5=md5,
                        size_bytes=size_bytes,
                        last_modified=last_modified,
                        status=FileStatus.ACTIVE,
                    )
                    session.add(file_hash)

                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=normalized_path,
                        event_type=EventType.CREATED,
                        new_sha256=sha256,
                        new_md5=md5,
                        size_bytes=size_bytes,
                        webhook_status=WebhookStatus.PENDING,
                    )
                    session.add(change)
                    detected_changes.append(change)

                elif existing.status == FileStatus.DELETED:
                    existing.environment_id = environment.id
                    existing.monitored_path_id = monitored.id
                    existing.sha256 = sha256
                    existing.md5 = md5
                    existing.size_bytes = size_bytes
                    existing.last_modified = last_modified
                    existing.status = FileStatus.ACTIVE
                    existing.updated_at = utc_now()
                    session.add(existing)

                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=normalized_path,
                        event_type=EventType.CREATED,
                        new_sha256=sha256,
                        new_md5=md5,
                        size_bytes=size_bytes,
                    )
                    session.add(change)
                    detected_changes.append(change)

                elif existing.sha256 != sha256:
                    old_sha256 = existing.sha256
                    old_md5 = existing.md5
                    existing.environment_id = environment.id
                    existing.monitored_path_id = monitored.id
                    existing.sha256 = sha256
                    existing.md5 = md5
                    existing.size_bytes = size_bytes
                    existing.last_modified = last_modified
                    existing.updated_at = utc_now()
                    session.add(existing)

                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=normalized_path,
                        event_type=EventType.MODIFIED,
                        old_sha256=old_sha256,
                        new_sha256=sha256,
                        old_md5=old_md5,
                        new_md5=md5,
                        size_bytes=size_bytes,
                    )
                    session.add(change)
                    detected_changes.append(change)

            known_files = session.exec(
                select(FileHash).where(
                    FileHash.environment_id == environment.id,
                    FileHash.monitored_path_id == monitored.id,
                    FileHash.status == FileStatus.ACTIVE,
                )
            ).all()

            for known in known_files:
                if known.path not in current_paths:
                    known.status = FileStatus.DELETED
                    known.updated_at = utc_now()
                    session.add(known)

                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=known.path,
                        event_type=EventType.DELETED,
                        old_sha256=known.sha256,
                        old_md5=known.md5,
                        size_bytes=known.size_bytes,
                    )
                    session.add(change)
                    detected_changes.append(change)

        scan.files_checked = files_checked
        scan.changes_found = len(detected_changes)
        scan.finished_at = utc_now()
        scan.status = ScanStatus.OK
        session.add(scan)
        session.commit()

        for change in detected_changes:
            session.refresh(change)
            notify_change(session, change)

        return scan

    except Exception as exc:
        scan.finished_at = utc_now()
        scan.status = ScanStatus.ERROR
        scan.error_message = str(exc)[:1000]
        session.add(scan)
        session.commit()
        return scan
