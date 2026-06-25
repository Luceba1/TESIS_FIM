from fastapi import APIRouter, Depends
from sqlmodel import Session

from app.core.db import get_session
from app.schemas import MetricsRead
from app.services.metrics import get_metrics

router = APIRouter(prefix="/metrics", tags=["Métricas"])


@router.get("", response_model=MetricsRead)
def metrics(session: Session = Depends(get_session)):
    return get_metrics(session)
