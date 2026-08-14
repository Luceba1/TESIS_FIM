from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import SQLModel, Session, create_engine, select

from app.models import Environment, EventType, FileChange, FileHash, MonitoredPath, ScanRun, ScanStatus
from app.services import fim_service
from app.services.fim_service import generate_baseline, run_scan
from app.services.metrics import get_metrics


@pytest.fixture()
def session():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    SQLModel.metadata.create_all(engine)
    with Session(engine) as db_session:
        yield db_session


@pytest.fixture(autouse=True)
def disable_webhook(monkeypatch):
    monkeypatch.setattr(fim_service, "notify_change", lambda session, change: None)


def create_environment_with_path(session: Session, root: Path) -> tuple[Environment, MonitoredPath]:
    environment = Environment(name=f"env-{root.name}")
    session.add(environment)
    session.commit()
    session.refresh(environment)

    monitored = MonitoredPath(environment_id=environment.id, path=str(root), recursive=True)
    session.add(monitored)
    session.commit()
    session.refresh(monitored)
    return environment, monitored


def test_modification_does_not_replace_approved_baseline(session: Session, tmp_path: Path):
    environment, _ = create_environment_with_path(session, tmp_path)
    target = tmp_path / "config.txt"
    target.write_text("original", encoding="utf-8")

    generate_baseline(session, environment_id=environment.id)
    baseline = session.exec(select(FileHash).where(FileHash.path == str(target.resolve()))).one()
    approved_sha256 = baseline.sha256

    target.write_text("alterado", encoding="utf-8")
    scan = run_scan(session, environment_id=environment.id)

    assert scan.status == ScanStatus.OK
    baseline = session.get(FileHash, baseline.id)
    assert baseline.sha256 == approved_sha256
    assert baseline.observed_sha256 != approved_sha256
    assert baseline.baseline_approved is True

    change = session.exec(select(FileChange).where(FileChange.event_type == EventType.MODIFIED)).one()
    assert change.baseline_sha256 == approved_sha256
    assert change.new_sha256 == baseline.observed_sha256
    assert change.baseline_match is False
    assert change.occurred_at is not None
    assert change.occurred_at_source == "FILE_MTIME"



def test_created_file_is_observed_but_not_implicitly_approved(session: Session, tmp_path: Path):
    environment, _ = create_environment_with_path(session, tmp_path)
    baseline_file = tmp_path / "config.txt"
    baseline_file.write_text("baseline", encoding="utf-8")
    generate_baseline(session, environment_id=environment.id)

    created = tmp_path / "created.txt"
    created.write_text("nuevo", encoding="utf-8")
    run_scan(session, environment_id=environment.id)

    file_hash = session.exec(select(FileHash).where(FileHash.path == str(created.resolve()))).one()
    assert file_hash.baseline_approved is False
    assert file_hash.baseline_approved_at is None
    assert file_hash.sha256 == ""
    assert file_hash.observed_sha256 != ""


def test_unchanged_observed_state_does_not_repeat_modified_alert(session: Session, tmp_path: Path):
    environment, _ = create_environment_with_path(session, tmp_path)
    target = tmp_path / "config.txt"
    target.write_text("original", encoding="utf-8")
    generate_baseline(session, environment_id=environment.id)

    target.write_text("alterado", encoding="utf-8")
    run_scan(session, environment_id=environment.id)
    run_scan(session, environment_id=environment.id)

    modifications = session.exec(select(FileChange).where(FileChange.event_type == EventType.MODIFIED)).all()
    assert len(modifications) == 1


def test_deleted_event_requires_external_time_reference_for_true_mttd(session: Session, tmp_path: Path):
    environment, _ = create_environment_with_path(session, tmp_path)
    target = tmp_path / "backup.sql"
    target.write_text("data", encoding="utf-8")
    generate_baseline(session, environment_id=environment.id)

    target.unlink()
    run_scan(session, environment_id=environment.id)

    change = session.exec(select(FileChange).where(FileChange.event_type == EventType.DELETED)).one()
    assert change.occurred_at is None
    assert change.occurred_at_source == "UNKNOWN"


def test_single_unreadable_file_marks_scan_partial_without_false_delete(session: Session, tmp_path: Path, monkeypatch):
    environment, _ = create_environment_with_path(session, tmp_path)
    good = tmp_path / "good.txt"
    blocked = tmp_path / "blocked.txt"
    good.write_text("v1", encoding="utf-8")
    blocked.write_text("v1", encoding="utf-8")
    generate_baseline(session, environment_id=environment.id)

    good.write_text("v2", encoding="utf-8")
    original_file_metadata = fim_service.file_metadata

    def selective_metadata(path: Path, max_attempts: int = 3):
        if path.name == "blocked.txt":
            raise PermissionError("archivo bloqueado para prueba")
        return original_file_metadata(path, max_attempts=max_attempts)

    monkeypatch.setattr(fim_service, "file_metadata", selective_metadata)
    scan = run_scan(session, environment_id=environment.id)

    assert scan.status == ScanStatus.PARTIAL
    assert scan.files_skipped == 1
    assert "blocked.txt" in scan.warning_message

    changes = session.exec(select(FileChange)).all()
    assert any(change.event_type == EventType.MODIFIED and change.path.endswith("good.txt") for change in changes)
    assert not any(change.event_type == EventType.DELETED and change.path.endswith("blocked.txt") for change in changes)


def test_mttd_metric_uses_event_occurrence_not_scan_start(session: Session, tmp_path: Path):
    environment, monitored = create_environment_with_path(session, tmp_path)
    base = datetime(2026, 8, 11, 4, 0, 0, tzinfo=timezone.utc)

    scan = ScanRun(
        environment_id=environment.id,
        started_at=base,
        finished_at=base + timedelta(seconds=20),
        status=ScanStatus.OK,
    )
    session.add(scan)
    session.commit()
    session.refresh(scan)

    change = FileChange(
        environment_id=environment.id,
        monitored_path_id=monitored.id,
        scan_run_id=scan.id,
        path=str(tmp_path / "metric.txt"),
        event_type=EventType.MODIFIED,
        occurred_at=base + timedelta(seconds=8),
        occurred_at_source="EXPERIMENT_CONTROLLED",
        detected_at=base + timedelta(seconds=13),
    )
    session.add(change)
    session.commit()

    metrics = get_metrics(session)
    assert metrics["average_mttd_seconds"] == 5.0
    assert metrics["average_scan_processing_seconds"] == 13.0
    assert metrics["mttd_sample_count"] == 1
    assert metrics["mttd_missing_count"] == 0


def test_timezone_offsets_are_compared_as_the_same_instant():
    from app.core.time_utils import seconds_between

    occurred = datetime.fromisoformat("2026-08-11T02:16:17.973707-03:00")
    detected = datetime.fromisoformat("2026-08-11T05:16:19.886476+00:00")

    assert seconds_between(detected, occurred) == pytest.approx(1.912769, abs=1e-6)


def test_operational_datetime_columns_are_timezone_aware():
    timezone_columns = [
        Environment.__table__.c.created_at,
        MonitoredPath.__table__.c.created_at,
        FileHash.__table__.c.last_modified,
        FileHash.__table__.c.baseline_approved_at,
        FileHash.__table__.c.observed_last_modified,
        FileHash.__table__.c.last_seen_at,
        FileHash.__table__.c.updated_at,
        ScanRun.__table__.c.started_at,
        ScanRun.__table__.c.finished_at,
        FileChange.__table__.c.occurred_at,
        FileChange.__table__.c.detected_at,
        FileChange.__table__.c.reviewed_at,
    ]

    assert all(column.type.timezone is True for column in timezone_columns)
