from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import AgentHeartbeat
from app.services.background_monitor import monitor

router = APIRouter(prefix="/agent", tags=["Agente"])


@router.get("/heartbeat")
def heartbeat(session: Session = Depends(get_session)):
    latest = session.exec(select(AgentHeartbeat).order_by(AgentHeartbeat.last_seen_at.desc())).first()
    if not latest:
        return {"status": "NO_DATA", "message": "Todavía no hay registros del agente"}
    return latest


@router.get("/status")
def monitor_status():
    return monitor.status()


@router.post("/start")
def start_monitor():
    started = monitor.start()
    return {"started": started, **monitor.status()}


@router.post("/stop")
def stop_monitor():
    stopped = monitor.stop()
    return {"stopped": stopped, **monitor.status()}
