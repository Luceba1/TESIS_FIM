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

    # Línea base aprobada.
    sha256: str
    md5: str
    size_bytes: int
    last_modified: datetime
    baseline_approved: bool
    baseline_approved_at: datetime | None

    # Último estado observado.
    observed_sha256: str
    observed_md5: str
    observed_size_bytes: int
    observed_last_modified: datetime | None
    last_seen_at: datetime | None

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
    baseline_sha256: str
    baseline_md5: str
    baseline_match: bool | None
    size_bytes: int
    occurred_at: datetime | None = None
    occurred_at_source: str
    detected_at: datetime
    reviewed_at: datetime | None = None

    # MTTD real cuando existe una referencia temporal del evento.
    detection_time_seconds: float | None = None
    # Latencia interna del escaneo, separada del MTTD.
    scan_processing_time_seconds: float | None = None
    response_time_seconds: float | None = None

    review_status: ChangeReviewStatus
    webhook_status: WebhookStatus
    webhook_error: str
    environment_name: str = ""
    environment_criticality: str = ""

    model_config = ConfigDict(from_attributes=True)


class EventTimeUpdate(BaseModel):
    occurred_at: datetime
    source: str = "EXPERIMENT_CONTROLLED"


class ScanRunRead(BaseModel):
    id: int
    environment_id: int | None
    started_at: datetime
    finished_at: datetime | None
    files_checked: int
    files_skipped: int
    changes_found: int
    status: ScanStatus
    error_message: str
    warning_message: str

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
    average_scan_processing_seconds: float | None = None
    average_mttr_seconds: float | None = None
    mttd_sample_count: int = 0
    mttd_missing_count: int = 0
