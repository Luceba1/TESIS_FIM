CREATE TABLE IF NOT EXISTS environments (
    id SERIAL PRIMARY KEY,
    name VARCHAR NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    criticality VARCHAR NOT NULL DEFAULT 'MEDIUM',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS monitored_paths (
    id SERIAL PRIMARY KEY,
    environment_id INTEGER NOT NULL REFERENCES environments(id),
    path TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    criticality VARCHAR NOT NULL DEFAULT 'MEDIUM',
    recursive BOOLEAN NOT NULL DEFAULT TRUE,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- file_hashes conserva dos estados distintos:
-- 1) sha256/md5/... = línea base APROBADA;
-- 2) observed_* = último estado observado por el motor.
-- Una alerta nunca reemplaza silenciosamente la referencia aprobada.
CREATE TABLE IF NOT EXISTS file_hashes (
    id SERIAL PRIMARY KEY,
    environment_id INTEGER NOT NULL REFERENCES environments(id),
    monitored_path_id INTEGER NOT NULL REFERENCES monitored_paths(id),
    path TEXT NOT NULL UNIQUE,

    sha256 TEXT NOT NULL DEFAULT '',
    md5 TEXT NOT NULL DEFAULT '',
    size_bytes BIGINT NOT NULL DEFAULT 0,
    last_modified TIMESTAMPTZ NOT NULL,
    baseline_approved BOOLEAN NOT NULL DEFAULT FALSE,
    baseline_approved_at TIMESTAMPTZ,

    observed_sha256 TEXT NOT NULL DEFAULT '',
    observed_md5 TEXT NOT NULL DEFAULT '',
    observed_size_bytes BIGINT NOT NULL DEFAULT 0,
    observed_last_modified TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ,

    status VARCHAR NOT NULL DEFAULT 'ACTIVE',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS scan_runs (
    id SERIAL PRIMARY KEY,
    environment_id INTEGER NULL REFERENCES environments(id),
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ NULL,
    files_checked INTEGER NOT NULL DEFAULT 0,
    files_skipped INTEGER NOT NULL DEFAULT 0,
    changes_found INTEGER NOT NULL DEFAULT 0,
    status VARCHAR NOT NULL DEFAULT 'RUNNING',
    error_message TEXT NOT NULL DEFAULT '',
    warning_message TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS file_changes (
    id SERIAL PRIMARY KEY,
    environment_id INTEGER NOT NULL REFERENCES environments(id),
    monitored_path_id INTEGER NOT NULL REFERENCES monitored_paths(id),
    scan_run_id INTEGER NOT NULL REFERENCES scan_runs(id),
    path TEXT NOT NULL,
    event_type VARCHAR NOT NULL,

    old_sha256 TEXT NOT NULL DEFAULT '',
    new_sha256 TEXT NOT NULL DEFAULT '',
    old_md5 TEXT NOT NULL DEFAULT '',
    new_md5 TEXT NOT NULL DEFAULT '',

    baseline_sha256 TEXT NOT NULL DEFAULT '',
    baseline_md5 TEXT NOT NULL DEFAULT '',
    baseline_match BOOLEAN,

    size_bytes BIGINT NOT NULL DEFAULT 0,
    occurred_at TIMESTAMPTZ,
    occurred_at_source TEXT NOT NULL DEFAULT 'UNKNOWN',
    detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at TIMESTAMPTZ,
    review_status VARCHAR NOT NULL DEFAULT 'PENDING',
    webhook_status VARCHAR NOT NULL DEFAULT 'PENDING',
    webhook_error TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS app_settings (
    key VARCHAR PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS agent_heartbeat (
    id SERIAL PRIMARY KEY,
    hostname VARCHAR NOT NULL,
    pid INTEGER NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR NOT NULL DEFAULT 'ACTIVE',
    message TEXT NOT NULL DEFAULT ''
);
