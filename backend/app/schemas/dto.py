from datetime import datetime
from pydantic import BaseModel, ConfigDict

from app.models import ChangeReviewStatus, Criticality, EventType, FileStatus, ScanStatus, WebhookStatus


class EnvironmentCreate(BaseModel):
    name: str
    description: str = ""
    criticality: Criticality = Criticality.MEDIUM
    enabled: bool = True


class EnvironmentRead(BaseModel):
    id: int
    name: str
    description: str
    criticality: Criticality
    enabled: bool
    created_at: datetime
    paths_count: int = 0
    active_files: int = 0
    events_today: int = 0
    pending_events: int = 0

    model_config = ConfigDict(from_attributes=True)


class EnvironmentUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    criticality: Criticality | None = None
    enabled: bool | None = None


class MonitoredPathCreate(BaseModel):
    environment_id: int
    path: str
    description: str = ""
    criticality: Criticality = Criticality.MEDIUM
    recursive: bool = True
    enabled: bool = True


class MonitoredPathRead(BaseModel):
    id: int
    environment_id: int
    path: str
    description: str
    criticality: Criticality
    recursive: bool
    enabled: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class MonitoredPathUpdate(BaseModel):
    description: str | None = None
    criticality: Criticality | None = None
    recursive: bool | None = None
    enabled: bool | None = None


class FileHashRead(BaseModel):
    id: int
    environment_id: int
    monitored_path_id: int
    path: str
    sha256: str
    md5: str
    size_bytes: int
    last_modified: datetime
    status: FileStatus
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class FileChangeRead(BaseModel):
    id: int
    environment_id: int
    monitored_path_id: int
    scan_run_id: int
    path: str
    event_type: EventType
    old_sha256: str
    new_sha256: str
    old_md5: str
    new_md5: str
    size_bytes: int
    detected_at: datetime
    reviewed_at: datetime | None = None
    detection_time_seconds: float | None = None
    response_time_seconds: float | None = None
    review_status: ChangeReviewStatus
    webhook_status: WebhookStatus
    webhook_error: str
    environment_name: str = ""
    environment_criticality: str = ""

    model_config = ConfigDict(from_attributes=True)


class ScanRunRead(BaseModel):
    id: int
    environment_id: int | None
    started_at: datetime
    finished_at: datetime | None
    files_checked: int
    changes_found: int
    status: ScanStatus
    error_message: str

    model_config = ConfigDict(from_attributes=True)


class SettingUpdate(BaseModel):
    value: str


class MetricsRead(BaseModel):
    environments: int
    monitored_paths: int
    active_files: int
    events_today: int
    pending_events: int
    reviewed_events: int
    ignored_events: int
    false_positive_events: int
    scans_today: int
    created_events: int
    modified_events: int
    deleted_events: int
    critical_events_today: int
    last_scan_at: datetime | None
    last_scan_status: str | None
    agent_last_seen_at: datetime | None
    average_mttd_seconds: float | None = None
    average_mttr_seconds: float | None = None
