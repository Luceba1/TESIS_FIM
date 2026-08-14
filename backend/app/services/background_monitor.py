import os
import socket
import threading
import time
from datetime import datetime, timezone
from typing import Optional

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.db import engine
from app.models import AgentHeartbeat
from app.services.fim_service import run_scan


class BackgroundMonitor:
    """Small in-process monitor used by the FastAPI app.

    It scans all enabled environments sequentially in a daemon thread, so the user
    does not need to open a second console with `python -m app.agent` during the
    demo or normal local use.
    """

    def __init__(self) -> None:
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._lock = threading.Lock()
        self.started_at: Optional[datetime] = None
        self.last_scan_at: Optional[datetime] = None
        self.last_scan_id: Optional[int] = None
        self.last_status: str = "STOPPED"
        self.last_message: str = "Monitor detenido"
        self.last_error: str = ""

    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive() and not self._stop_event.is_set()

    def start(self) -> bool:
        with self._lock:
            if self.is_running():
                return False
            self._stop_event.clear()
            self.started_at = datetime.now(timezone.utc)
            self.last_status = "STARTING"
            self.last_message = "Iniciando monitoreo automático"
            self.last_error = ""
            self._thread = threading.Thread(target=self._loop, name="WatchDogsFIMMonitor", daemon=True)
            self._thread.start()
            return True

    def stop(self) -> bool:
        with self._lock:
            if not self.is_running():
                self.last_status = "STOPPED"
                self.last_message = "Monitor detenido"
                return False
            self._stop_event.set()
            self.last_status = "STOPPING"
            self.last_message = "Deteniendo monitoreo automático"
            return True

    def status(self) -> dict:
        return {
            "running": self.is_running(),
            "started_at": self.started_at,
            "last_scan_at": self.last_scan_at,
            "last_scan_id": self.last_scan_id,
            "status": self.last_status,
            "message": self.last_message,
            "last_error": self.last_error,
            "interval_seconds": get_settings().scan_interval_seconds,
        }

    def _update_heartbeat(self, session: Session, status: str, message: str) -> None:
        hostname = socket.gethostname()
        existing = session.exec(select(AgentHeartbeat).where(AgentHeartbeat.hostname == hostname)).first()
        now = datetime.now(timezone.utc)
        if existing:
            existing.pid = os.getpid()
            existing.last_seen_at = now
            existing.status = status
            existing.message = message
            session.add(existing)
        else:
            session.add(AgentHeartbeat(hostname=hostname, pid=os.getpid(), last_seen_at=now, status=status, message=message))
        session.commit()

    def _loop(self) -> None:
        settings = get_settings()
        self.last_status = "ACTIVE"
        self.last_message = "Monitoreo automático activo"

        while not self._stop_event.is_set():
            try:
                with Session(engine) as session:
                    scan = run_scan(session)
                    self.last_scan_at = datetime.now(timezone.utc)
                    self.last_scan_id = scan.id
                    self.last_status = scan.status.value
                    self.last_message = (
                        f"Último escaneo #{scan.id}: {scan.status.value}, "
                        f"archivos: {scan.files_checked}, omitidos: {scan.files_skipped}, "
                        f"cambios: {scan.changes_found}"
                    )
                    self.last_error = scan.error_message or ""
                    self._update_heartbeat(session, "ACTIVE", self.last_message)
            except Exception as exc:  # defensive: monitoring should not kill the API
                self.last_status = "ERROR"
                self.last_error = str(exc)[:1000]
                self.last_message = f"Error en monitoreo automático: {self.last_error}"
                try:
                    with Session(engine) as session:
                        self._update_heartbeat(session, "ERROR", self.last_message)
                except Exception:
                    pass

            self._stop_event.wait(settings.scan_interval_seconds)

        self.last_status = "STOPPED"
        self.last_message = "Monitor detenido"
        try:
            with Session(engine) as session:
                self._update_heartbeat(session, "STOPPED", self.last_message)
        except Exception:
            pass


monitor = BackgroundMonitor()
