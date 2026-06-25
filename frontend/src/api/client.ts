const API_URL = import.meta.env.VITE_API_URL ?? "http://127.0.0.1:8000/api/v1";

export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(`${API_URL}${path}`, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers ?? {}),
    },
    ...options,
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || "Error de API");
  }

  return response.json();
}

export type Metrics = {
  environments: number;
  monitored_paths: number;
  active_files: number;
  events_today: number;
  pending_events: number;
  reviewed_events: number;
  ignored_events: number;
  false_positive_events: number;
  scans_today: number;
  created_events: number;
  modified_events: number;
  deleted_events: number;
  critical_events_today: number;
  last_scan_at: string | null;
  last_scan_status: string | null;
  agent_last_seen_at: string | null;
};

export type Environment = {
  id: number;
  name: string;
  description: string;
  criticality: string;
  enabled: boolean;
  created_at: string;
  paths_count: number;
  active_files: number;
  events_today: number;
  pending_events: number;
};

export type MonitoredPath = {
  id: number;
  environment_id: number;
  path: string;
  description: string;
  criticality: string;
  recursive: boolean;
  enabled: boolean;
  created_at: string;
};

export type FileChange = {
  id: number;
  environment_id: number;
  monitored_path_id: number;
  scan_run_id: number;
  environment_name: string;
  environment_criticality: string;
  path: string;
  event_type: "CREATED" | "MODIFIED" | "DELETED";
  old_sha256: string;
  new_sha256: string;
  old_md5: string;
  new_md5: string;
  size_bytes: number;
  detected_at: string;
  review_status: "PENDING" | "REVIEWED" | "IGNORED" | "FALSE_POSITIVE" | string;
  webhook_status: string;
  webhook_error: string;
};

export type AgentStatus = {
  running: boolean;
  started_at: string | null;
  last_scan_at: string | null;
  last_scan_id: number | null;
  status: string;
  message: string;
  last_error: string;
  interval_seconds: number;
};
