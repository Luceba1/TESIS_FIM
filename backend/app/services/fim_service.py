import os
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


def normalize_path(path: Path) -> str:
    """Normaliza una ruta sin exigir que el archivo siga existiendo."""
    return os.path.abspath(os.path.normpath(str(path)))


def collect_files(root: Path, recursive: bool = True) -> tuple[list[Path], list[str]]:
    """Enumera archivos sin dejar que un error de una subcarpeta aborte el escaneo.

    Devuelve los archivos visibles y una lista de advertencias. Si existe cualquier
    advertencia de enumeración, el llamador puede evitar inferir eliminaciones en
    esa ruta para no producir falsos positivos por falta de permisos.
    """
    if not root.exists() or not root.is_dir():
        raise ValueError(f"La ruta no existe o no es una carpeta: {root}")

    files: list[Path] = []
    warnings: list[str] = []

    if not recursive:
        try:
            for item in root.iterdir():
                try:
                    if item.is_file():
                        files.append(item)
                except OSError as exc:
                    warnings.append(f"No se pudo inspeccionar {item}: {exc}")
        except OSError as exc:
            warnings.append(f"No se pudo enumerar {root}: {exc}")
        return files, warnings

    def onerror(exc: OSError) -> None:
        location = getattr(exc, "filename", None) or str(root)
        warnings.append(f"No se pudo enumerar {location}: {exc}")

    for directory, _, filenames in os.walk(root, onerror=onerror, followlinks=False):
        for filename in filenames:
            files.append(Path(directory) / filename)

    return files, warnings


def file_metadata(path: Path, max_attempts: int = 3) -> tuple[str, str, int, datetime]:
    """Calcula hashes y metadatos verificando que el archivo no cambie durante la lectura.

    No existe una lectura atómica genérica para cualquier archivo de Windows. Para
    reducir eventos espurios se compara ``stat`` antes y después del hashing y se
    reintenta si tamaño o mtime cambiaron durante la operación.
    """
    last_error: Exception | None = None

    for _ in range(max_attempts):
        try:
            before = path.stat()
            sha256, md5 = calculate_hashes(path)
            after = path.stat()
        except (OSError, PermissionError) as exc:
            last_error = exc
            continue

        if before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns:
            last_modified = datetime.fromtimestamp(after.st_mtime, tz=timezone.utc)
            return sha256, md5, after.st_size, last_modified

        last_error = RuntimeError(f"El archivo cambió mientras era leído: {path}")

    if last_error:
        raise last_error
    raise RuntimeError(f"No se pudo obtener un estado estable del archivo: {path}")


def enabled_paths_query(environment_id: int | None = None):
    query = (
        select(MonitoredPath, Environment)
        .join(Environment, Environment.id == MonitoredPath.environment_id)
        .where(MonitoredPath.enabled == True, Environment.enabled == True)  # noqa: E712
    )
    if environment_id is not None:
        query = query.where(Environment.id == environment_id)
    return query


def _set_observed_state(
    file_hash: FileHash,
    *,
    sha256: str,
    md5: str,
    size_bytes: int,
    last_modified: datetime,
    seen_at: datetime | None = None,
) -> None:
    file_hash.observed_sha256 = sha256
    file_hash.observed_md5 = md5
    file_hash.observed_size_bytes = size_bytes
    file_hash.observed_last_modified = last_modified
    file_hash.last_seen_at = seen_at or utc_now()
    file_hash.status = FileStatus.ACTIVE
    file_hash.updated_at = utc_now()


def _ensure_observed_state(file_hash: FileHash) -> None:
    """Compatibilidad con filas creadas antes de separar baseline/observación."""
    if not file_hash.observed_sha256 and file_hash.sha256:
        file_hash.observed_sha256 = file_hash.sha256
        file_hash.observed_md5 = file_hash.md5
        file_hash.observed_size_bytes = file_hash.size_bytes
        file_hash.observed_last_modified = file_hash.last_modified
        file_hash.last_seen_at = file_hash.updated_at


def _baseline_match(file_hash: FileHash, observed_sha256: str | None) -> bool | None:
    if not file_hash.baseline_approved or not file_hash.sha256 or observed_sha256 is None:
        return None
    return file_hash.sha256 == observed_sha256


def generate_baseline(
    session: Session,
    monitored_path_id: int | None = None,
    environment_id: int | None = None,
) -> dict:
    """Genera/aprueba explícitamente una línea base a partir del estado actual.

    Esta es una acción deliberada del operador. A diferencia de ``run_scan``, es el
    único flujo normal que reemplaza el hash de referencia aprobado.
    """
    query = enabled_paths_query(environment_id)
    if monitored_path_id is not None:
        query = query.where(MonitoredPath.id == monitored_path_id)

    rows = session.exec(query).all()
    files_count = 0
    files_skipped = 0
    warnings: list[str] = []
    approved_at = utc_now()

    for monitored, environment in rows:
        root = Path(monitored.path)
        try:
            file_paths, enumeration_warnings = collect_files(root, monitored.recursive)
            warnings.extend(enumeration_warnings)
        except Exception as exc:
            warnings.append(str(exc))
            continue

        for file_path in file_paths:
            normalized_path = normalize_path(file_path)
            try:
                sha256, md5, size_bytes, last_modified = file_metadata(file_path)
            except Exception as exc:
                files_skipped += 1
                warnings.append(f"{normalized_path}: {exc}")
                continue

            existing = session.exec(select(FileHash).where(FileHash.path == normalized_path)).first()
            if existing:
                existing.environment_id = environment.id
                existing.monitored_path_id = monitored.id
                existing.sha256 = sha256
                existing.md5 = md5
                existing.size_bytes = size_bytes
                existing.last_modified = last_modified
                existing.baseline_approved = True
                existing.baseline_approved_at = approved_at
                _set_observed_state(
                    existing,
                    sha256=sha256,
                    md5=md5,
                    size_bytes=size_bytes,
                    last_modified=last_modified,
                    seen_at=approved_at,
                )
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
                        baseline_approved=True,
                        baseline_approved_at=approved_at,
                        observed_sha256=sha256,
                        observed_md5=md5,
                        observed_size_bytes=size_bytes,
                        observed_last_modified=last_modified,
                        last_seen_at=approved_at,
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
        "files_skipped": files_skipped,
        "warnings": warnings[:50],
        "baseline_approved_at": approved_at,
    }


def approve_current_state(session: Session, file_hash_id: int) -> FileHash | None:
    """Aprueba explícitamente el último estado observado como nueva línea base."""
    file_hash = session.get(FileHash, file_hash_id)
    if not file_hash:
        return None

    _ensure_observed_state(file_hash)
    if file_hash.status != FileStatus.ACTIVE or not file_hash.observed_sha256:
        raise ValueError("No hay un estado observado activo que pueda aprobarse como línea base.")

    file_hash.sha256 = file_hash.observed_sha256
    file_hash.md5 = file_hash.observed_md5
    file_hash.size_bytes = file_hash.observed_size_bytes
    file_hash.last_modified = file_hash.observed_last_modified or file_hash.last_modified
    file_hash.baseline_approved = True
    file_hash.baseline_approved_at = utc_now()
    file_hash.updated_at = utc_now()
    session.add(file_hash)
    session.commit()
    session.refresh(file_hash)
    return file_hash


def run_scan(session: Session, environment_id: int | None = None) -> ScanRun:
    scan = ScanRun(status=ScanStatus.RUNNING, started_at=utc_now(), environment_id=environment_id)
    session.add(scan)
    session.commit()
    session.refresh(scan)

    detected_changes: list[FileChange] = []
    files_checked = 0
    files_skipped = 0
    warnings: list[str] = []

    try:
        rows = session.exec(enabled_paths_query(environment_id)).all()

        for monitored, environment in rows:
            root = Path(monitored.path)
            current_paths: set[str] = set()
            enumeration_failed = False

            try:
                file_paths, enumeration_warnings = collect_files(root, monitored.recursive)
                if enumeration_warnings:
                    enumeration_failed = True
                    warnings.extend(enumeration_warnings)
            except Exception as exc:
                enumeration_failed = True
                warnings.append(f"Ruta {monitored.path}: {exc}")
                continue

            for file_path in file_paths:
                normalized_path = normalize_path(file_path)
                # La ruta existe en la enumeración aunque luego no pueda leerse. Esto
                # evita clasificarla erróneamente como DELETED.
                current_paths.add(normalized_path)

                try:
                    sha256, md5, size_bytes, last_modified = file_metadata(file_path)
                except Exception as exc:
                    files_skipped += 1
                    warnings.append(f"{normalized_path}: {exc}")
                    continue

                files_checked += 1
                observed_at = utc_now()
                existing = session.exec(select(FileHash).where(FileHash.path == normalized_path)).first()

                if existing is None:
                    # Un archivo que aparece durante el monitoreo NO se convierte en
                    # línea base automáticamente. Se conserva como estado observado
                    # hasta aprobación explícita del operador.
                    file_hash = FileHash(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        path=normalized_path,
                        sha256="",
                        md5="",
                        size_bytes=0,
                        last_modified=last_modified,
                        baseline_approved=False,
                        baseline_approved_at=None,
                        observed_sha256=sha256,
                        observed_md5=md5,
                        observed_size_bytes=size_bytes,
                        observed_last_modified=last_modified,
                        last_seen_at=observed_at,
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
                        baseline_sha256="",
                        baseline_md5="",
                        baseline_match=None,
                        size_bytes=size_bytes,
                        occurred_at=last_modified,
                        occurred_at_source="FILE_MTIME",
                        webhook_status=WebhookStatus.PENDING,
                    )
                    session.add(change)
                    detected_changes.append(change)
                    continue

                _ensure_observed_state(existing)
                previous_observed_sha256 = existing.observed_sha256 or existing.sha256
                previous_observed_md5 = existing.observed_md5 or existing.md5

                if existing.status == FileStatus.DELETED:
                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=normalized_path,
                        event_type=EventType.CREATED,
                        old_sha256=previous_observed_sha256,
                        new_sha256=sha256,
                        old_md5=previous_observed_md5,
                        new_md5=md5,
                        baseline_sha256=existing.sha256,
                        baseline_md5=existing.md5,
                        baseline_match=_baseline_match(existing, sha256),
                        size_bytes=size_bytes,
                        occurred_at=last_modified,
                        occurred_at_source="FILE_MTIME",
                    )
                    session.add(change)
                    detected_changes.append(change)

                elif previous_observed_sha256 != sha256:
                    change = FileChange(
                        environment_id=environment.id,
                        monitored_path_id=monitored.id,
                        scan_run_id=scan.id,
                        path=normalized_path,
                        event_type=EventType.MODIFIED,
                        old_sha256=previous_observed_sha256,
                        new_sha256=sha256,
                        old_md5=previous_observed_md5,
                        new_md5=md5,
                        baseline_sha256=existing.sha256,
                        baseline_md5=existing.md5,
                        baseline_match=_baseline_match(existing, sha256),
                        size_bytes=size_bytes,
                        occurred_at=last_modified,
                        occurred_at_source="FILE_MTIME",
                    )
                    session.add(change)
                    detected_changes.append(change)

                existing.environment_id = environment.id
                existing.monitored_path_id = monitored.id
                _set_observed_state(
                    existing,
                    sha256=sha256,
                    md5=md5,
                    size_bytes=size_bytes,
                    last_modified=last_modified,
                    seen_at=observed_at,
                )
                session.add(existing)

            # Si la enumeración fue incompleta no inferimos eliminaciones, porque
            # una carpeta inaccesible puede ocultar archivos que siguen existiendo.
            if enumeration_failed:
                continue

            known_files = session.exec(
                select(FileHash).where(
                    FileHash.environment_id == environment.id,
                    FileHash.monitored_path_id == monitored.id,
                    FileHash.status == FileStatus.ACTIVE,
                )
            ).all()

            for known in known_files:
                if known.path in current_paths:
                    continue

                _ensure_observed_state(known)
                old_sha256 = known.observed_sha256 or known.sha256
                old_md5 = known.observed_md5 or known.md5
                known.status = FileStatus.DELETED
                known.updated_at = utc_now()
                session.add(known)

                change = FileChange(
                    environment_id=environment.id,
                    monitored_path_id=monitored.id,
                    scan_run_id=scan.id,
                    path=known.path,
                    event_type=EventType.DELETED,
                    old_sha256=old_sha256,
                    old_md5=old_md5,
                    baseline_sha256=known.sha256,
                    baseline_md5=known.md5,
                    baseline_match=False if known.baseline_approved and known.sha256 else None,
                    size_bytes=known.observed_size_bytes or known.size_bytes,
                    occurred_at=None,
                    occurred_at_source="UNKNOWN",
                )
                session.add(change)
                detected_changes.append(change)

        scan.files_checked = files_checked
        scan.files_skipped = files_skipped
        scan.changes_found = len(detected_changes)
        scan.finished_at = utc_now()
        scan.warning_message = "\n".join(warnings)[:4000]
        scan.status = ScanStatus.PARTIAL if warnings or files_skipped else ScanStatus.OK
        session.add(scan)
        session.commit()

        # La evidencia queda persistida antes de intentar integraciones externas.
        for change in detected_changes:
            session.refresh(change)
            notify_change(session, change)

        return scan

    except Exception as exc:
        session.rollback()
        scan = session.get(ScanRun, scan.id) or scan
        scan.finished_at = utc_now()
        scan.files_checked = files_checked
        scan.files_skipped = files_skipped
        scan.changes_found = len(detected_changes)
        scan.status = ScanStatus.ERROR
        scan.error_message = str(exc)[:1000]
        scan.warning_message = "\n".join(warnings)[:4000]
        session.add(scan)
        session.commit()
        return scan
