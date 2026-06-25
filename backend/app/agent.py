import os
import socket
import time
from datetime import datetime, timezone

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.db import create_db_and_tables, engine
from app.models import AgentHeartbeat
from app.services.fim_service import run_scan


def update_heartbeat(session: Session, message: str = "") -> None:
    hostname = socket.gethostname()
    existing = session.exec(select(AgentHeartbeat).where(AgentHeartbeat.hostname == hostname)).first()
    if existing:
        existing.pid = os.getpid()
        existing.last_seen_at = datetime.now(timezone.utc)
        existing.status = "ACTIVE"
        existing.message = message
        session.add(existing)
    else:
        session.add(
            AgentHeartbeat(
                hostname=hostname,
                pid=os.getpid(),
                status="ACTIVE",
                message=message,
            )
        )
    session.commit()


def main() -> None:
    settings = get_settings()
    create_db_and_tables()

    print("WatchDogs FIM Agent iniciado")
    print(f"Intervalo de escaneo: {settings.scan_interval_seconds} segundos")

    while True:
        with Session(engine) as session:
            scan = run_scan(session)
            update_heartbeat(
                session,
                message=f"Último escaneo #{scan.id}: {scan.status.value}, cambios: {scan.changes_found}",
            )
            print(f"Scan #{scan.id} | estado={scan.status.value} | archivos={scan.files_checked} | cambios={scan.changes_found}")

        time.sleep(settings.scan_interval_seconds)


if __name__ == "__main__":
    main()
