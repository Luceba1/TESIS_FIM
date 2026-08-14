from datetime import datetime, timezone


def as_utc(value: datetime | None) -> datetime | None:
    """Devuelve una marca temporal normalizada a UTC.

    PostgreSQL usa TIMESTAMPTZ para las marcas operativas del proyecto. El caso
    ``tzinfo is None`` se conserva solo como defensa para SQLite/tests o datos que
    no hayan pasado todavía por la migración de compatibilidad.
    """
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def seconds_between(end: datetime | None, start: datetime | None) -> float | None:
    end_utc = as_utc(end)
    start_utc = as_utc(start)
    if end_utc is None or start_utc is None:
        return None
    return max(0.0, (end_utc - start_utc).total_seconds())


def iso_utc(value: datetime | None) -> str | None:
    normalized = as_utc(value)
    return normalized.isoformat() if normalized else None
