from datetime import datetime, timedelta, timezone

from sqlalchemy.pool import StaticPool
from sqlmodel import SQLModel, Session, create_engine

from app.models import Environment, EventType, FileChange, FileHash, FileStatus, MonitoredPath, ScanRun, ScanStatus
from app.services.metrics import get_metrics


def make_session() -> Session:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    SQLModel.metadata.create_all(engine)
    return Session(engine)


def test_metrics_do_not_mix_mttd_sources():
    with make_session() as session:
        environment = Environment(name="metrics-source-env")
        session.add(environment)
        session.commit()
        session.refresh(environment)

        monitored = MonitoredPath(environment_id=environment.id, path="C:/tmp", recursive=True)
        session.add(monitored)
        session.commit()
        session.refresh(monitored)

        base = datetime(2026, 8, 11, 4, 0, 0, tzinfo=timezone.utc)
        scan = ScanRun(environment_id=environment.id, started_at=base, finished_at=base + timedelta(seconds=20), status=ScanStatus.OK)
        session.add(scan)
        session.commit()
        session.refresh(scan)

        session.add(
            FileChange(
                environment_id=environment.id,
                monitored_path_id=monitored.id,
                scan_run_id=scan.id,
                path="C:/tmp/operational.txt",
                event_type=EventType.MODIFIED,
                occurred_at=base + timedelta(seconds=1),
                occurred_at_source="FILE_MTIME",
                detected_at=base + timedelta(seconds=5),
            )
        )
        session.add(
            FileChange(
                environment_id=environment.id,
                monitored_path_id=monitored.id,
                scan_run_id=scan.id,
                path="C:/tmp/experimental.txt",
                event_type=EventType.MODIFIED,
                occurred_at=base + timedelta(seconds=2),
                occurred_at_source="EXPERIMENT_CONTROLLED",
                detected_at=base + timedelta(seconds=12),
            )
        )
        session.commit()

        metrics = get_metrics(session)

        assert metrics["mttd_source"] == "FILE_MTIME"
        assert metrics["average_mttd_seconds"] == 4.0
        assert metrics["mttd_sample_count"] == 1
        assert metrics["mttd_excluded_source_count"] == 1
        assert metrics["mttd_by_source"]["FILE_MTIME"]["average_seconds"] == 4.0
        assert metrics["mttd_by_source"]["EXPERIMENT_CONTROLLED"]["average_seconds"] == 10.0


def test_active_files_counts_only_approved_baseline_and_partial_is_visible():
    with make_session() as session:
        environment = Environment(name="baseline-count-env")
        session.add(environment)
        session.commit()
        session.refresh(environment)

        monitored = MonitoredPath(environment_id=environment.id, path="C:/tmp", recursive=True)
        session.add(monitored)
        session.commit()
        session.refresh(monitored)

        observed_at = datetime(2026, 8, 11, 4, 0, 0, tzinfo=timezone.utc)
        session.add(
            FileHash(
                environment_id=environment.id,
                monitored_path_id=monitored.id,
                path="C:/tmp/approved.txt",
                sha256="approved",
                md5="approved",
                size_bytes=1,
                last_modified=observed_at,
                baseline_approved=True,
                baseline_approved_at=observed_at,
                observed_sha256="approved",
                observed_md5="approved",
                observed_size_bytes=1,
                observed_last_modified=observed_at,
                last_seen_at=observed_at,
                status=FileStatus.ACTIVE,
            )
        )
        session.add(
            FileHash(
                environment_id=environment.id,
                monitored_path_id=monitored.id,
                path="C:/tmp/observed-only.txt",
                sha256="",
                md5="",
                size_bytes=0,
                last_modified=observed_at,
                observed_sha256="observed",
                observed_md5="observed",
                observed_size_bytes=1,
                observed_last_modified=observed_at,
                last_seen_at=observed_at,
                baseline_approved=False,
                status=FileStatus.ACTIVE,
            )
        )
        scan = ScanRun(
            environment_id=environment.id,
            status=ScanStatus.PARTIAL,
            files_checked=9,
            files_skipped=1,
        )
        session.add(scan)
        session.commit()

        metrics = get_metrics(session)

        assert metrics["active_files"] == 1
        assert metrics["last_scan_files_checked"] == 9
        assert metrics["last_scan_files_skipped"] == 1
        assert metrics["last_scan_status"] == "PARTIAL · omitidos=1"
