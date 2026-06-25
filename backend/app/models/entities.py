from datetime import datetime, timezone
from enum import Enum
from typing import Optional

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
    created_at: datetime = Field(default_factory=utc_now)


class MonitoredPath(SQLModel, table=True):
    __tablename__ = "monitored_paths"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    path: str = Field(index=True, unique=True)
    description: str = ""
    criticality: Criticality = Field(default=Criticality.MEDIUM)
    recursive: bool = True
    enabled: bool = True
    created_at: datetime = Field(default_factory=utc_now)


class FileHash(SQLModel, table=True):
    __tablename__ = "file_hashes"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    monitored_path_id: int = Field(foreign_key="monitored_paths.id", index=True)
    path: str = Field(index=True, unique=True)
    sha256: str = Field(index=True)
    md5: str = ""
    size_bytes: int = 0
    last_modified: datetime
    status: FileStatus = Field(default=FileStatus.ACTIVE)
    updated_at: datetime = Field(default_factory=utc_now)


class ScanRun(SQLModel, table=True):
    __tablename__ = "scan_runs"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: Optional[int] = Field(default=None, foreign_key="environments.id", index=True)
    started_at: datetime = Field(default_factory=utc_now)
    finished_at: Optional[datetime] = None
    files_checked: int = 0
    changes_found: int = 0
    status: ScanStatus = Field(default=ScanStatus.RUNNING)
    error_message: str = ""


class FileChange(SQLModel, table=True):
    __tablename__ = "file_changes"

    id: Optional[int] = Field(default=None, primary_key=True)
    environment_id: int = Field(foreign_key="environments.id", index=True)
    monitored_path_id: int = Field(foreign_key="monitored_paths.id", index=True)
    scan_run_id: int = Field(foreign_key="scan_runs.id", index=True)
    path: str = Field(index=True)
    event_type: EventType
    old_sha256: str = ""
    new_sha256: str = ""
    old_md5: str = ""
    new_md5: str = ""
    size_bytes: int = 0
    detected_at: datetime = Field(default_factory=utc_now)
    reviewed_at: Optional[datetime] = None
    review_status: ChangeReviewStatus = Field(default=ChangeReviewStatus.PENDING)
    webhook_status: WebhookStatus = Field(default=WebhookStatus.PENDING)
    webhook_error: str = ""


class AppSetting(SQLModel, table=True):
    __tablename__ = "app_settings"

    key: str = Field(primary_key=True)
    value: str = ""
    updated_at: datetime = Field(default_factory=utc_now)


class AgentHeartbeat(SQLModel, table=True):
    __tablename__ = "agent_heartbeat"

    id: Optional[int] = Field(default=None, primary_key=True)
    hostname: str = Field(index=True)
    pid: int
    last_seen_at: datetime = Field(default_factory=utc_now)
    status: str = "ACTIVE"
    message: str = ""
