from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlmodel import Session

from app.core.db import get_session
from app.models import AppSetting
from app.schemas import SettingUpdate
from app.services.notifier import WEBHOOK_KEY, get_webhook_status, retry_failed_webhooks, test_webhook

router = APIRouter(prefix="/settings", tags=["Configuración"])


@router.get("/webhook")
def get_webhook(session: Session = Depends(get_session)):
    setting = session.get(AppSetting, WEBHOOK_KEY)
    return {"key": WEBHOOK_KEY, "value": setting.value if setting else ""}


@router.put("/webhook")
def set_webhook(payload: SettingUpdate, session: Session = Depends(get_session)):
    setting = session.get(AppSetting, WEBHOOK_KEY)
    if setting:
        setting.value = payload.value
        setting.updated_at = datetime.now(timezone.utc)
    else:
        setting = AppSetting(key=WEBHOOK_KEY, value=payload.value)
    session.add(setting)
    session.commit()
    return {"key": WEBHOOK_KEY, "value": setting.value}


@router.get("/webhook/status")
def webhook_status(session: Session = Depends(get_session)):
    return get_webhook_status(session)


@router.post("/webhook/test")
def webhook_test(session: Session = Depends(get_session)):
    return test_webhook(session)


@router.post("/webhook/retry-failed")
def retry_failed(session: Session = Depends(get_session)):
    count = retry_failed_webhooks(session)
    return {"retried": count}
