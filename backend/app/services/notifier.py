import requests
from sqlmodel import Session, select

from app.core.config import get_settings
from app.models import AppSetting, Environment, FileChange, WebhookStatus


WEBHOOK_KEY = "n8n_webhook_url"


def get_webhook_url(session: Session) -> str:
    configured = session.get(AppSetting, WEBHOOK_KEY)
    if configured and configured.value.strip():
        return configured.value.strip()
    return get_settings().n8n_webhook_url.strip()


def notify_change(session: Session, change: FileChange) -> None:
    webhook_url = get_webhook_url(session)
    environment = session.get(Environment, change.environment_id)

    if not webhook_url:
        change.webhook_status = WebhookStatus.NOT_CONFIGURED
        session.add(change)
        session.commit()
        return

    payload = {
        "id": change.id,
        "environment_id": change.environment_id,
        "environment_name": environment.name if environment else "Entorno desconocido",
        "environment_criticality": environment.criticality.value if environment else "",
        "path": change.path,
        "event_type": change.event_type.value,
        "old_sha256": change.old_sha256,
        "new_sha256": change.new_sha256,
        "detected_at": change.detected_at.isoformat(),
        "scan_run_id": change.scan_run_id,
        "review_status": change.review_status.value,
        "message": f"Alerta en entorno {environment.name if environment else 'desconocido'}: {change.event_type.value} en {change.path}",
    }

    try:
        response = requests.post(webhook_url, json=payload, timeout=5)
        response.raise_for_status()
        change.webhook_status = WebhookStatus.SENT
        change.webhook_error = ""
    except Exception as exc:
        change.webhook_status = WebhookStatus.FAILED
        change.webhook_error = str(exc)[:500]

    session.add(change)
    session.commit()


def retry_failed_webhooks(session: Session) -> int:
    changes = session.exec(select(FileChange).where(FileChange.webhook_status == WebhookStatus.FAILED)).all()

    for change in changes:
        notify_change(session, change)

    return len(changes)
