from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.core.db import get_session
from app.models import ScanRun
from app.schemas import ScanRunRead
from app.services.fim_service import run_scan

router = APIRouter(prefix="/scan-runs", tags=["Escaneos"])


@router.post("/run", response_model=ScanRunRead)
def run_scan_now(environment_id: int | None = None, session: Session = Depends(get_session)):
    return run_scan(session, environment_id=environment_id)


@router.get("", response_model=list[ScanRunRead])
def list_scan_runs(environment_id: int | None = None, session: Session = Depends(get_session)):
    query = select(ScanRun).order_by(ScanRun.started_at.desc()).limit(50)
    if environment_id is not None:
        query = query.where(ScanRun.environment_id == environment_id)
    return session.exec(query).all()
