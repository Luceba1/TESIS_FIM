import ctypes
import sys
from ctypes import wintypes

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import SQLModel, Session, create_engine, select

from app.models import Environment, EventType, FileChange, MonitoredPath, ScanStatus
from app.services import fim_service
from app.services.fim_service import generate_baseline, run_scan


pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="requiere semántica real de bloqueo de archivos de Windows")


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


def _open_exclusive_windows_handle(path: str):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    create_file = kernel32.CreateFileW
    create_file.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    create_file.restype = wintypes.HANDLE

    generic_read = 0x80000000
    generic_write = 0x40000000
    open_existing = 3
    file_attribute_normal = 0x80
    invalid_handle_value = wintypes.HANDLE(-1).value

    handle = create_file(
        path,
        generic_read | generic_write,
        0,  # sin FILE_SHARE_*: bloqueo real para otros opens
        None,
        open_existing,
        file_attribute_normal,
        None,
    )
    if handle == invalid_handle_value:
        raise OSError(ctypes.get_last_error(), f"CreateFileW no pudo bloquear {path}")
    return kernel32, handle


def test_real_windows_locked_file_marks_scan_partial_without_false_delete(session, tmp_path, monkeypatch):
    monkeypatch.setattr(fim_service, "notify_change", lambda session, change: None)

    environment = Environment(name="windows-lock-e2e")
    session.add(environment)
    session.commit()
    session.refresh(environment)

    monitored = MonitoredPath(environment_id=environment.id, path=str(tmp_path), recursive=True)
    session.add(monitored)
    session.commit()

    good = tmp_path / "good.txt"
    blocked = tmp_path / "blocked.txt"
    good.write_text("v1", encoding="utf-8")
    blocked.write_text("v1", encoding="utf-8")
    generate_baseline(session, environment_id=environment.id)

    good.write_text("v2", encoding="utf-8")
    kernel32, handle = _open_exclusive_windows_handle(str(blocked))
    try:
        scan = run_scan(session, environment_id=environment.id)
    finally:
        kernel32.CloseHandle(handle)

    assert scan.status == ScanStatus.PARTIAL
    assert scan.files_skipped >= 1
    assert "blocked.txt" in (scan.warning_message or "")

    changes = session.exec(select(FileChange)).all()
    assert any(change.event_type == EventType.MODIFIED and change.path.endswith("good.txt") for change in changes)
    assert not any(change.event_type == EventType.DELETED and change.path.endswith("blocked.txt") for change in changes)
