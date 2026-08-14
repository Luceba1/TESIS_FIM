import requests
from sqlmodel import Session, select
from datetime import datetime, timezone

from app.core.config import get_settings
from app.core.time_utils import iso_utc
from app.models import AppSetting, Environment, FileChange, WebhookStatus


WEBHOOK_KEY = "n8n_webhook_url"
WEBHOOK_LAST_TEST_AT_KEY = "n8n_webhook_last_test_at"
WEBHOOK_LAST_TEST_STATUS_KEY = "n8n_webhook_last_test_status"
WEBHOOK_LAST_TEST_ERROR_KEY = "n8n_webhook_last_test_error"
WEBHOOK_LAST_SENT_AT_KEY = "n8n_webhook_last_sent_at"
WEBHOOK_LAST_ERROR_AT_KEY = "n8n_webhook_last_error_at"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _upsert_setting(session: Session, key: str, value: str) -> None:
    setting = session.get(AppSetting, key)
    if setting:
        setting.value = value
        setting.updated_at = datetime.now(timezone.utc)
    else:
        setting = AppSetting(key=key, value=value)
    session.add(setting)


def get_setting_value(session: Session, key: str, default: str = "") -> str:
    setting = session.get(AppSetting, key)
    return setting.value if setting else default


def get_webhook_url(session: Session) -> str:
    configured = session.get(AppSetting, WEBHOOK_KEY)
    if configured and configured.value.strip():
        return configured.value.strip()
    return get_settings().n8n_webhook_url.strip()


def build_change_payload(session: Session, change: FileChange) -> dict:
    environment = session.get(Environment, change.environment_id)
    environment_name = environment.name if environment else "Entorno desconocido"
    environment_criticality = environment.criticality.value if environment else ""
    file_name = change.path.replace("\\", "/").split("/")[-1]

    return {
        "source": "WatchDogs FIM",
        "type": "FILE_INTEGRITY_EVENT",
        "id": change.id,
        "environment_id": change.environment_id,
        "environment_name": environment_name,
        "environment_criticality": environment_criticality,
        "event_type": change.event_type.value,
        "event_label": {
            "CREATED": "Archivo creado",
            "MODIFIED": "Archivo modificado",
            "DELETED": "Archivo eliminado",
        }.get(change.event_type.value, change.event_type.value),
        "file_name": file_name,
        "path": change.path,
        "old_sha256": change.old_sha256,
        "new_sha256": change.new_sha256,
        "old_md5": change.old_md5,
        "new_md5": change.new_md5,
        "size_bytes": change.size_bytes,
        "occurred_at": iso_utc(change.occurred_at),
        "occurred_at_source": change.occurred_at_source,
        "detected_at": iso_utc(change.detected_at),
        "baseline_sha256": change.baseline_sha256,
        "baseline_match": change.baseline_match,
        "scan_run_id": change.scan_run_id,
        "review_status": change.review_status.value,
        "message": f"Alerta WatchDogs FIM: {change.event_type.value} en {environment_name} - {change.path}",
    }


def notify_change(session: Session, change: FileChange) -> None:
    webhook_url = get_webhook_url(session)

    if not webhook_url:
        change.webhook_status = WebhookStatus.NOT_CONFIGURED
        session.add(change)
        session.commit()
        return

    payload = build_change_payload(session, change)

    try:
        response = requests.post(webhook_url, json=payload, timeout=5)
        response.raise_for_status()
        change.webhook_status = WebhookStatus.SENT
        change.webhook_error = ""
        _upsert_setting(session, WEBHOOK_LAST_SENT_AT_KEY, _now_iso())
    except Exception as exc:
        change.webhook_status = WebhookStatus.FAILED
        change.webhook_error = str(exc)[:500]
        _upsert_setting(session, WEBHOOK_LAST_ERROR_AT_KEY, _now_iso())

    session.add(change)
    session.commit()


def test_webhook(session: Session) -> dict:
    webhook_url = get_webhook_url(session)
    sent_at = _now_iso()

    if not webhook_url:
        _upsert_setting(session, WEBHOOK_LAST_TEST_AT_KEY, sent_at)
        _upsert_setting(session, WEBHOOK_LAST_TEST_STATUS_KEY, "NOT_CONFIGURED")
        _upsert_setting(session, WEBHOOK_LAST_TEST_ERROR_KEY, "No hay webhook configurado.")
        session.commit()
        return {
            "ok": False,
            "status": "NOT_CONFIGURED",
            "message": "No hay webhook configurado.",
            "sent_at": sent_at,
        }

    payload = {
        "source": "WatchDogs FIM",
        "type": "TEST",
        "message": "Prueba de conexión con n8n realizada desde WatchDogs FIM.",
        "sent_at": sent_at,
    }

    try:
        response = requests.post(webhook_url, json=payload, timeout=5)
        response.raise_for_status()
        _upsert_setting(session, WEBHOOK_LAST_TEST_AT_KEY, sent_at)
        _upsert_setting(session, WEBHOOK_LAST_TEST_STATUS_KEY, "OK")
        _upsert_setting(session, WEBHOOK_LAST_TEST_ERROR_KEY, "")
        session.commit()
        return {
            "ok": True,
            "status": "OK",
            "message": "Conexión con n8n realizada correctamente.",
            "sent_at": sent_at,
            "http_status": response.status_code,
        }
    except Exception as exc:
        error = str(exc)[:500]
        _upsert_setting(session, WEBHOOK_LAST_TEST_AT_KEY, sent_at)
        _upsert_setting(session, WEBHOOK_LAST_TEST_STATUS_KEY, "ERROR")
        _upsert_setting(session, WEBHOOK_LAST_TEST_ERROR_KEY, error)
        session.commit()
        return {
            "ok": False,
            "status": "ERROR",
            "message": "No se pudo conectar con n8n.",
            "sent_at": sent_at,
            "error": error,
        }


def get_webhook_status(session: Session) -> dict:
    webhook_url = get_webhook_url(session)
    failed_count = session.exec(
        select(FileChange).where(FileChange.webhook_status == WebhookStatus.FAILED)
    ).all()
    not_configured_count = session.exec(
        select(FileChange).where(FileChange.webhook_status == WebhookStatus.NOT_CONFIGURED)
    ).all()

    return {
        "configured": bool(webhook_url),
        "url": webhook_url,
        "last_test_at": get_setting_value(session, WEBHOOK_LAST_TEST_AT_KEY),
        "last_test_status": get_setting_value(session, WEBHOOK_LAST_TEST_STATUS_KEY),
        "last_test_error": get_setting_value(session, WEBHOOK_LAST_TEST_ERROR_KEY),
        "last_sent_at": get_setting_value(session, WEBHOOK_LAST_SENT_AT_KEY),
        "last_error_at": get_setting_value(session, WEBHOOK_LAST_ERROR_AT_KEY),
        "failed_events": len(failed_count),
        "not_configured_events": len(not_configured_count),
    }


def retry_failed_webhooks(session: Session) -> int:
    changes = session.exec(select(FileChange).where(FileChange.webhook_status == WebhookStatus.FAILED)).all()

    for change in changes:
        notify_change(session, change)

    return len(changes)


def retry_change_webhook(session: Session, change_id: int) -> FileChange | None:
    change = session.get(FileChange, change_id)
    if not change:
        return None
    notify_change(session, change)
    session.refresh(change)
    return change
