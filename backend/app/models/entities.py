from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from sqlalchemy import DateTime
from sqlmodel import Field, SQLModel


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class EventType(str, Enum):
    CREATED = "CREATED"
    MODIFIED = "MODIFIED"
    DELETED = "DELETED"


class FileStatus(str, Enum):
    ACTIVE = "ACTIVE"
    DELETED = "DELETED"


class ChangeReviewStatus(str, Enum):
    PENDING = "PENDING"
    REVIEWED = "REVIEWED"
    IGNORED = "IGNORED"
    FALSE_POSITIVE = "FALSE_POSITIVE"


class ScanStatus(str, Enum):
    RUNNING = "RUNNING"
    OK = "OK"
    PARTIAL = "PARTIAL"
    ERROR = "ERROR"


class WebhookStatus(str, Enum):
    NOT_CONFIGURED = "NOT_CONFIGURED"
    PENDING = "PENDING"
    SENT = "SENT"
    FAILED = "FAILED"


class Criticality(str, Enum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"


class Environment(SQLModel, table=True):
    __tablename__ = "environments"

    id: Optional[int] = Field(default=None, primary_key=True)
    name: str = Field(index=True, unique=True)
    description: str = ""
    criticality: Criticality = Field(default=Criticality.MEDIUM)
    enabled: bool = True
    created_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))


class MonitoredPath(SQLModel, table=True):
    __tablename__ = "monitored_paths"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    path: str = Field(index=True, unique=True)
    description: str = ""
    criticality: Criticality = Field(default=Criticality.MEDIUM)
    recursive: bool = True
    enabled: bool = True
    created_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))


class FileHash(SQLModel, table=True):
    """Línea base aprobada + último estado observado de un archivo.

    Los campos ``sha256``, ``md5``, ``size_bytes`` y ``last_modified`` representan
    la línea base aprobada. Los campos ``observed_*`` representan el último estado
    visto por el motor. Separarlos evita que una modificación detectada legitime de
    forma automática el nuevo contenido.
    """

    __tablename__ = "file_hashes"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    monitored_path_id: int = Field(foreign_key="monitored_paths.id", index=True)
    path: str = Field(index=True, unique=True)

    # Línea base aprobada.
    sha256: str = Field(default="", index=True)
    md5: str = ""
    size_bytes: int = 0
    last_modified: datetime = Field(sa_type=DateTime(timezone=True))
    # Un registro observado nunca se considera baseline por defecto. Solo los
    # flujos explícitos de generación/aprobación pueden activar esta bandera.
    baseline_approved: bool = False
    baseline_approved_at: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))

    # Último estado observado. No modifica silenciosamente la línea base.
    observed_sha256: str = Field(default="", index=True)
    observed_md5: str = ""
    observed_size_bytes: int = 0
    observed_last_modified: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))
    last_seen_at: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))

    status: FileStatus = Field(default=FileStatus.ACTIVE)
    updated_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))


class ScanRun(SQLModel, table=True):
    __tablename__ = "scan_runs"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: Optional[int] = Field(default=None, foreign_key="environments.id", index=True)
    started_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))
    finished_at: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))
    files_checked: int = 0
    files_skipped: int = 0
    changes_found: int = 0
    status: ScanStatus = Field(default=ScanStatus.RUNNING)
    error_message: str = ""
    warning_message: str = ""


class FileChange(SQLModel, table=True):
    __tablename__ = "file_changes"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    monitored_path_id: int = Field(foreign_key="monitored_paths.id", index=True)
    scan_run_id: int = Field(foreign_key="scan_runs.id", index=True)
    path: str = Field(index=True)
    event_type: EventType

    # Estado anterior y nuevo observado.
    old_sha256: str = ""
    new_sha256: str = ""
    old_md5: str = ""
    new_md5: str = ""

    # Referencia aprobada al momento del evento.
    baseline_sha256: str = ""
    baseline_md5: str = ""
    baseline_match: Optional[bool] = None

    size_bytes: int = 0

    # ``occurred_at`` es la referencia temporal del cambio cuando puede
    # determinarse. En CREATED/MODIFIED se aproxima con mtime; en una prueba
    # controlada puede reemplazarse por la marca temporal registrada por el
    # script experimental. Para DELETED queda nulo salvo que se aporte esa marca.
    occurred_at: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))
    occurred_at_source: str = "UNKNOWN"
    detected_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))

    reviewed_at: Optional[datetime] = Field(default=None, sa_type=DateTime(timezone=True))
    review_status: ChangeReviewStatus = Field(default=ChangeReviewStatus.PENDING)
    webhook_status: WebhookStatus = Field(default=WebhookStatus.PENDING)
    webhook_error: str = ""


class AppSetting(SQLModel, table=True):
    __tablename__ = "app_settings"

    key: str = Field(primary_key=True)
    value: str = ""
    updated_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))


class AgentHeartbeat(SQLModel, table=True):
    __tablename__ = "agent_heartbeat"

    id: Optional[int] = Field(default=None, primary_key=True)
    hostname: str = Field(index=True)
    pid: int
    last_seen_at: datetime = Field(default_factory=utc_now, sa_type=DateTime(timezone=True))
    status: str = "ACTIVE"
    message: str = ""
