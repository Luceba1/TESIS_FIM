import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Activity,
  AlertTriangle,
  BellRing,
  CheckCircle2,
  Clock3,
  Database,
  Eye,
  FolderCog,
  FolderPlus,
  Play,
  RefreshCcw,
  ShieldAlert,
  ShieldCheck,
  Square,
  Download,
  Send,
  Wifi,
  X,
} from "lucide-react";
import { api, API_URL, AgentStatus, Environment, FileChange, Metrics, MonitoredPath, WebhookIntegrationStatus } from "./api/client";
import "./styles.css";

const criticalities = ["LOW", "MEDIUM", "HIGH", "CRITICAL"];
const reviewStatuses = ["PENDING", "REVIEWED", "IGNORED", "FALSE_POSITIVE"];

function formatDate(value?: string | null) {
  if (!value) return "-";
  return new Date(value).toLocaleString("es-AR");
}

function formatDuration(seconds?: number | null) {
  if (seconds === null || seconds === undefined) return "Sin datos";
  if (seconds < 1) return "< 1s";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const minutes = Math.floor(seconds / 60);
  const restSeconds = Math.round(seconds % 60);
  if (minutes < 60) return `${minutes}m ${restSeconds}s`;
  const hours = Math.floor(minutes / 60);
  const restMinutes = minutes % 60;
  return `${hours}h ${restMinutes}m`;
}

function fileName(path: string) {
  return path.split(/[\\/]/).pop() || path;
}

function shortHash(hash: string) {
  if (!hash) return "-";
  return `${hash.slice(0, 12)}...${hash.slice(-8)}`;
}

function formatStatus(status: string) {
  const labels: Record<string, string> = {
    PENDING: "Pendiente",
    REVIEWED: "Revisado",
    IGNORED: "Ignorado",
    FALSE_POSITIVE: "Falso positivo",
    NOT_CONFIGURED: "No configurado",
    SENT: "Enviado",
    FAILED: "Falló",
    OK: "Correcto",
    TEST: "Prueba",
    ERROR: "Error",
    PARTIAL: "Parcial",
  };
  return labels[status] ?? status;
}

function eventLabel(type: string) {
  if (type === "CREATED") return "Archivo creado";
  if (type === "MODIFIED") return "Archivo modificado";
  if (type === "DELETED") return "Archivo eliminado";
  return type;
}

function eventClass(type: string) {
  return `badge ${type.toLowerCase()}`;
}

function StatCard({ title, value, icon, hint }: { title: string; value: string | number; icon: React.ReactNode; hint?: string }) {
  return (
    <div className="card stat-card">
      <div>
        <p className="muted">{title}</p>
        <h2>{value}</h2>
        {hint && <span className="mini-muted">{hint}</span>}
      </div>
      <div className="icon-box">{icon}</div>
    </div>
  );
}

function EmptyState({ title, text }: { title: string; text: string }) {
  return (
    <div className="empty-state">
      <ShieldAlert />
      <strong>{title}</strong>
      <p>{text}</p>
    </div>
  );
}

function App() {
  const [metrics, setMetrics] = useState<Metrics | null>(null);
  const [environments, setEnvironments] = useState<Environment[]>([]);
  const [paths, setPaths] = useState<MonitoredPath[]>([]);
  const [changes, setChanges] = useState<FileChange[]>([]);
  const [selectedEnvironmentId, setSelectedEnvironmentId] = useState<number | "all">("all");
  const [eventTypeFilter, setEventTypeFilter] = useState<string>("all");
  const [reviewFilter, setReviewFilter] = useState<string>("all");
  const [selectedChange, setSelectedChange] = useState<FileChange | null>(null);
  const [newEnvironmentName, setNewEnvironmentName] = useState("");
  const [newEnvironmentDescription, setNewEnvironmentDescription] = useState("");
  const [newEnvironmentCriticality, setNewEnvironmentCriticality] = useState("HIGH");
  const [newPath, setNewPath] = useState("");
  const [webhook, setWebhook] = useState("");
  const [webhookStatus, setWebhookStatus] = useState<WebhookIntegrationStatus | null>(null);
  const [webhookTestMessage, setWebhookTestMessage] = useState("");
  const [agentStatus, setAgentStatus] = useState<AgentStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const selectedEnvironment = useMemo(
    () => environments.find((item) => item.id === selectedEnvironmentId),
    [environments, selectedEnvironmentId]
  );

  const filteredChanges = changes.filter((change) => {
    if (eventTypeFilter !== "all" && change.event_type !== eventTypeFilter) return false;
    if (reviewFilter !== "all" && change.review_status !== reviewFilter) return false;
    return true;
  });

  const totalEvents = Math.max(1, (metrics?.created_events ?? 0) + (metrics?.modified_events ?? 0) + (metrics?.deleted_events ?? 0));

  async function loadData() {
    const query = selectedEnvironmentId === "all" ? "" : `?environment_id=${selectedEnvironmentId}`;
    const [metricsData, environmentsData, pathsData, changesData, webhookData, agentData, webhookStatusData] = await Promise.all([
      api<Metrics>("/metrics"),
      api<Environment[]>("/environments"),
      api<MonitoredPath[]>(`/paths${query}`),
      api<FileChange[]>(`/changes${query}`),
      api<{ value: string }>("/settings/webhook"),
      api<AgentStatus>("/agent/status"),
      api<WebhookIntegrationStatus>("/settings/webhook/status"),
    ]);
    setMetrics(metricsData);
    setEnvironments(environmentsData);
    setPaths(pathsData);
    setChanges(changesData);
    setWebhook(webhookData.value ?? "");
    setWebhookStatus(webhookStatusData);
    setAgentStatus(agentData);
  }

  useEffect(() => {
    loadData().catch((err) => setError(err.message));
    const interval = window.setInterval(() => loadData().catch((err) => setError(err.message)), 5000);
    return () => window.clearInterval(interval);
  }, [selectedEnvironmentId]);

  async function safeAction(action: () => Promise<void>) {
    setLoading(true);
    setError("");
    try {
      await action();
      await loadData();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Ocurrió un error");
    } finally {
      setLoading(false);
    }
  }

  async function createEnvironment() {
    if (!newEnvironmentName.trim()) return;
    await safeAction(async () => {
      const created = await api<Environment>("/environments", {
        method: "POST",
        body: JSON.stringify({
          name: newEnvironmentName,
          description: newEnvironmentDescription,
          criticality: newEnvironmentCriticality,
          enabled: true,
        }),
      });
      setNewEnvironmentName("");
      setNewEnvironmentDescription("");
      setSelectedEnvironmentId(created.id);
    });
  }

  async function createPath() {
    if (!newPath.trim() || selectedEnvironmentId === "all") return;
    await safeAction(async () => {
      await api("/paths", {
        method: "POST",
        body: JSON.stringify({
          environment_id: selectedEnvironmentId,
          path: newPath,
          description: `Ruta crítica del entorno ${selectedEnvironment?.name ?? "seleccionado"}`,
          criticality: selectedEnvironment?.criticality ?? "HIGH",
          recursive: true,
          enabled: true,
        }),
      });
      setNewPath("");
    });
  }

  async function generateBaseline() {
    await safeAction(async () => {
      const query = selectedEnvironmentId === "all" ? "" : `?environment_id=${selectedEnvironmentId}`;
      await api(`/baseline/generate${query}`, { method: "POST" });
    });
  }

  async function runScan() {
    await safeAction(async () => {
      const query = selectedEnvironmentId === "all" ? "" : `?environment_id=${selectedEnvironmentId}`;
      await api(`/scan-runs/run${query}`, { method: "POST" });
    });
  }

  async function saveWebhook() {
    await safeAction(async () => {
      await api("/settings/webhook", {
        method: "PUT",
        body: JSON.stringify({ value: webhook }),
      });
      setWebhookTestMessage("Webhook guardado correctamente.");
    });
  }

  async function testWebhook() {
    await safeAction(async () => {
      const result = await api<{ ok: boolean; message: string; status: string; error?: string }>("/settings/webhook/test", { method: "POST" });
      setWebhookTestMessage(result.ok ? result.message : `${result.message} ${result.error ?? ""}`);
    });
  }

  async function retryFailedWebhooks() {
    await safeAction(async () => {
      const result = await api<{ retried: number }>("/settings/webhook/retry-failed", { method: "POST" });
      setWebhookTestMessage(`Eventos reenviados a n8n: ${result.retried}`);
    });
  }

  async function retrySelectedWebhook(change: FileChange) {
    await safeAction(async () => {
      const updated = await api<FileChange>(`/changes/${change.id}/webhook/retry`, { method: "POST" });
      setSelectedChange(updated);
      setWebhookTestMessage(`Evento #${change.id} reenviado a n8n.`);
    });
  }

  async function updateReviewStatus(change: FileChange, status: string) {
    await safeAction(async () => {
      const updated = await api<FileChange>(`/changes/${change.id}/review?status=${status}`, { method: "PATCH" });
      setSelectedChange(updated);
    });
  }

  async function exportEvidence() {
    setLoading(true);
    setError("");
    try {
      const params = new URLSearchParams();
      if (selectedEnvironmentId !== "all") params.set("environment_id", String(selectedEnvironmentId));
      if (eventTypeFilter !== "all") params.set("event_type", eventTypeFilter);
      if (reviewFilter !== "all") params.set("review_status", reviewFilter);
      const query = params.toString() ? `?${params.toString()}` : "";
      const response = await fetch(`${API_URL}/changes/export${query}`);
      if (!response.ok) throw new Error(await response.text() || "No se pudo exportar la evidencia");
      const blob = await response.blob();
      const contentDisposition = response.headers.get("Content-Disposition") ?? "";
      const match = contentDisposition.match(/filename="?([^";]+)"?/i);
      const filename = match?.[1] ?? `watchdogs_fim_evidencia_${new Date().toISOString().slice(0, 10)}.csv`;
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Ocurrió un error al exportar evidencia");
    } finally {
      setLoading(false);
    }
  }


  async function startAgent() {
    await safeAction(async () => {
      await api("/agent/start", { method: "POST" });
    });
  }

  async function stopAgent() {
    await safeAction(async () => {
      await api("/agent/stop", { method: "POST" });
    });
  }

  return (
    <main className="layout">
      <section className="hero">
        <div>
          <p className="eyebrow">The WatchDogs</p>
          <h1>WatchDogs FIM</h1>
          <p className="subtitle">
            Entornos controlados para monitorear archivos críticos, detectar cambios y conservar evidencia técnica.
          </p>
        </div>
        <div className={`system-state ${agentStatus?.running ? "ok" : "warn"}`}>
          <span className="pulse"></span>
          {agentStatus?.running ? "Monitor activo" : "Monitor detenido"}
        </div>
      </section>

      {error && <div className="error-box">{error}</div>}

      <section className="grid stats">
        <StatCard title="Entornos" value={metrics?.environments ?? "-"} icon={<FolderCog />} hint="Grupos de monitoreo" />
        <StatCard title="Archivos activos" value={metrics?.active_files ?? "-"} icon={<Database />} hint="En línea base" />
        <StatCard title="Eventos hoy" value={metrics?.events_today ?? "-"} icon={<BellRing />} hint={`${metrics?.pending_events ?? 0} pendientes`} />
        <StatCard title="Escaneos hoy" value={metrics?.scans_today ?? "-"} icon={<RefreshCcw />} hint={metrics?.last_scan_status ?? "Sin datos"} />
        <StatCard
          title="MTTD promedio"
          value={formatDuration(metrics?.average_mttd_seconds)}
          icon={<Clock3 />}
          hint={`Evento → detección · n=${metrics?.mttd_sample_count ?? 0}${metrics?.mttd_missing_count ? ` · ${metrics.mttd_missing_count} sin referencia` : ""}`}
        />
        <StatCard title="Latencia de escaneo" value={formatDuration(metrics?.average_scan_processing_seconds)} icon={<Activity />} hint="Inicio de ciclo → registro" />
        <StatCard title="MTTR promedio" value={formatDuration(metrics?.average_mttr_seconds)} icon={<CheckCircle2 />} hint="Detección → revisión" />
      </section>

      <section className="grid two-columns top-gap">
        <div className="card">
          <div className="section-header">
            <div>
              <h2>Entornos controlados</h2>
              <p className="muted">Agrupá rutas críticas con un nombre claro para contextualizar cada alerta.</p>
            </div>
            <ShieldCheck />
          </div>

          <div className="form-grid">
            <input value={newEnvironmentName} onChange={(e) => setNewEnvironmentName(e.target.value)} placeholder="Nombre: Sistema Académico" />
            <select value={newEnvironmentCriticality} onChange={(e) => setNewEnvironmentCriticality(e.target.value)}>
              {criticalities.map((item) => <option key={item}>{item}</option>)}
            </select>
            <input value={newEnvironmentDescription} onChange={(e) => setNewEnvironmentDescription(e.target.value)} placeholder="Descripción breve" />
            <button onClick={createEnvironment} disabled={loading}>Crear entorno</button>
          </div>

          <div className="filter-row">
            <label>Vista actual</label>
            <select value={selectedEnvironmentId} onChange={(e) => setSelectedEnvironmentId(e.target.value === "all" ? "all" : Number(e.target.value))}>
              <option value="all">Todos los entornos</option>
              {environments.map((env) => <option key={env.id} value={env.id}>{env.name}</option>)}
            </select>
          </div>

          <div className="environment-grid">
            {environments.length === 0 && <EmptyState title="Todavía no hay entornos" text="Creá un entorno y agregale una ruta crítica para empezar." />}
            {environments.map((env) => (
              <button
                key={env.id}
                className={`environment-card ${selectedEnvironmentId === env.id ? "selected" : ""}`}
                onClick={() => setSelectedEnvironmentId(env.id)}
              >
                <div className="environment-title">
                  <strong>{env.name}</strong>
                  <span className={`badge severity-${env.criticality.toLowerCase()}`}>{env.criticality}</span>
                </div>
                <p>{env.description || "Sin descripción"}</p>
                <div className="environment-meta">
                  <span>{env.paths_count} rutas</span>
                  <span>{env.active_files} archivos</span>
                  <span>{env.pending_events} pendientes</span>
                </div>
              </button>
            ))}
          </div>
        </div>

        <div className="card">
          <div className="section-header">
            <div>
              <h2>{selectedEnvironment ? `Rutas de ${selectedEnvironment.name}` : "Rutas monitoreadas"}</h2>
              <p className="muted">Agregá carpetas, generá línea base y ejecutá escaneos.</p>
            </div>
            <Activity />
          </div>

          <div className="form-row">
            <input
              value={newPath}
              onChange={(e) => setNewPath(e.target.value)}
              placeholder="Ej: C:\\watchdogs_demo\\sistema_academico"
              disabled={selectedEnvironmentId === "all"}
            />
            <button onClick={createPath} disabled={loading || selectedEnvironmentId === "all"}>Agregar ruta</button>
          </div>

          <div className="actions">
            <button onClick={generateBaseline} disabled={loading}><ShieldCheck size={18} /> Generar línea base</button>
            <button onClick={runScan} disabled={loading} className="secondary"><Play size={18} /> Escanear ahora</button>
          </div>

          <div className="list compact-list">
            {paths.length === 0 && <EmptyState title="Sin rutas en esta vista" text="Seleccioná un entorno específico para agregar una ruta." />}
            {paths.map((path) => (
              <div key={path.id} className="list-item">
                <div>
                  <strong>{path.path}</strong>
                  <p className="muted">Recursivo: {path.recursive ? "sí" : "no"}</p>
                </div>
                <span className={`badge ${path.enabled ? "active" : "disabled"}`}>{path.enabled ? "Activa" : "Inactiva"}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="grid two-columns top-gap">
        <div className="card">
          <div className="section-header">
            <div>
              <h2>Panel de eventos</h2>
              <p className="muted">Gestión de alertas detectadas por el motor FIM.</p>
            </div>
            <AlertTriangle />
          </div>

          <div className="event-summary">
            <div>
              <span className="dot created-dot"></span>
              Creados: {metrics?.created_events ?? 0}
            </div>
            <div>
              <span className="dot modified-dot"></span>
              Modificados: {metrics?.modified_events ?? 0}
            </div>
            <div>
              <span className="dot deleted-dot"></span>
              Eliminados: {metrics?.deleted_events ?? 0}
            </div>
          </div>
          <div className="bar-chart" aria-label="Distribución de eventos">
            <div className="bar created-bar" style={{ width: `${((metrics?.created_events ?? 0) / totalEvents) * 100}%` }}></div>
            <div className="bar modified-bar" style={{ width: `${((metrics?.modified_events ?? 0) / totalEvents) * 100}%` }}></div>
            <div className="bar deleted-bar" style={{ width: `${((metrics?.deleted_events ?? 0) / totalEvents) * 100}%` }}></div>
          </div>

          <div className="filter-grid events-tools">
            <select value={eventTypeFilter} onChange={(e) => setEventTypeFilter(e.target.value)}>
              <option value="all">Todos los eventos</option>
              <option value="CREATED">Creados</option>
              <option value="MODIFIED">Modificados</option>
              <option value="DELETED">Eliminados</option>
            </select>
            <select value={reviewFilter} onChange={(e) => setReviewFilter(e.target.value)}>
              <option value="all">Todos los estados</option>
              {reviewStatuses.map((status) => <option key={status} value={status}>{formatStatus(status)}</option>)}
            </select>
            <button onClick={exportEvidence} disabled={loading} className="export-button">
              <Download size={18} /> Exportar evidencia CSV
            </button>
          </div>

          <div className="table event-table">
            <div className="table-row table-head">
              <span>Evento</span>
              <span>Archivo</span>
              <span>Entorno</span>
              <span>Estado</span>
              <span>Acción</span>
            </div>
            {filteredChanges.length === 0 && <EmptyState title="No hay eventos para mostrar" text="Cuando el monitor detecte cambios, aparecerán en esta tabla." />}
            {filteredChanges.map((change) => (
              <div className="table-row" key={change.id}>
                <span className={eventClass(change.event_type)}>{eventLabel(change.event_type)}</span>
                <div className="file-cell">
                  <strong>{fileName(change.path)}</strong>
                  <small>{formatDate(change.detected_at)}</small>
                  <small>MTTD: {formatDuration(change.detection_time_seconds)}</small>
                  <small>Fuente: {change.occurred_at_source || "UNKNOWN"}</small>
                </div>
                <div>
                  <strong>{change.environment_name}</strong>
                  <small className={`badge severity-${change.environment_criticality.toLowerCase()}`}>{change.environment_criticality}</small>
                </div>
                <span className={`badge review-${change.review_status.toLowerCase().replace("_", "-")}`}>{formatStatus(change.review_status)}</span>
                <button className="icon-button" onClick={() => setSelectedChange(change)}><Eye size={16} /> Ver</button>
              </div>
            ))}
          </div>
        </div>

        <div className="card">
          <div className="section-header">
            <div>
              <h2>Agente y automatización</h2>
              <p className="muted">Control del monitor automático e integración con n8n.</p>
            </div>
            <Clock3 />
          </div>

          <div className="agent-box">
            <div className="agent-status-line">
              <span className={`badge ${agentStatus?.running ? "active" : "disabled"}`}>{agentStatus?.running ? "Activo" : "Detenido"}</span>
              <strong>Intervalo: {agentStatus?.interval_seconds ?? "-"}s</strong>
            </div>
            <p className="muted">Último escaneo: {formatDate(agentStatus?.last_scan_at)}</p>
            <p className="muted">Último heartbeat: {formatDate(metrics?.agent_last_seen_at)}</p>
            <p className="mini-muted">{agentStatus?.message || "Sin mensajes del agente"}</p>
            {agentStatus?.last_error && <div className="error-box compact-error">{agentStatus.last_error}</div>}
            <div className="actions">
              <button onClick={startAgent} disabled={loading || agentStatus?.running}><Play size={18} /> Iniciar</button>
              <button onClick={stopAgent} disabled={loading || !agentStatus?.running} className="danger"><Square size={18} /> Detener</button>
            </div>
          </div>

          <div className="webhook-box">
            <div className="webhook-title-row">
              <label>Webhook n8n</label>
              <span className={`badge ${webhookStatus?.configured ? "active" : "disabled"}`}>
                {webhookStatus?.configured ? "Configurado" : "No configurado"}
              </span>
            </div>
            <input value={webhook} onChange={(e) => setWebhook(e.target.value)} placeholder="http://localhost:5678/webhook-test/watchdogs-alert" />
            <div className="actions webhook-actions">
              <button onClick={saveWebhook} disabled={loading}>Guardar webhook</button>
              <button onClick={testWebhook} disabled={loading || !webhook.trim()} className="secondary">Probar conexión</button>
              <button onClick={retryFailedWebhooks} disabled={loading || !webhookStatus?.failed_events} className="secondary">Reenviar fallidos</button>
            </div>

            <div className="webhook-status-grid">
              <div><span>Última prueba</span><strong>{formatStatus(webhookStatus?.last_test_status || "-")}</strong></div>
              <div><span>Fecha prueba</span><strong>{formatDate(webhookStatus?.last_test_at)}</strong></div>
              <div><span>Último envío real</span><strong>{formatDate(webhookStatus?.last_sent_at)}</strong></div>
              <div><span>Fallidos</span><strong>{webhookStatus?.failed_events ?? 0}</strong></div>
            </div>
            {webhookStatus?.last_test_error && <div className="error-box compact-error">{webhookStatus.last_test_error}</div>}
            {webhookTestMessage && <div className="success-box compact-success">{webhookTestMessage}</div>}
          </div>

          <div className="review-summary">
            <div><strong>{metrics?.pending_events ?? 0}</strong><span>Pendientes</span></div>
            <div><strong>{metrics?.reviewed_events ?? 0}</strong><span>Revisados</span></div>
            <div><strong>{metrics?.ignored_events ?? 0}</strong><span>Ignorados</span></div>
            <div><strong>{metrics?.false_positive_events ?? 0}</strong><span>Falsos positivos</span></div>
          </div>
        </div>
      </section>

      {selectedChange && (
        <div className="modal-backdrop" onClick={() => setSelectedChange(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div>
                <p className="eyebrow">Evidencia técnica</p>
                <h2>{eventLabel(selectedChange.event_type)}</h2>
              </div>
              <button className="icon-button" onClick={() => setSelectedChange(null)}><X size={18} /></button>
            </div>

            <div className="evidence-grid">
              <div><span>Entorno</span><strong>{selectedChange.environment_name}</strong></div>
              <div><span>Criticidad</span><strong>{selectedChange.environment_criticality}</strong></div>
              <div><span>Ocurrencia</span><strong>{formatDate(selectedChange.occurred_at)}</strong></div>
              <div><span>Fuente temporal</span><strong>{selectedChange.occurred_at_source || "UNKNOWN"}</strong></div>
              <div><span>Detectado</span><strong>{formatDate(selectedChange.detected_at)}</strong></div>
              <div><span>Revisado</span><strong>{formatDate(selectedChange.reviewed_at)}</strong></div>
              <div><span>MTTD</span><strong>{formatDuration(selectedChange.detection_time_seconds)}</strong></div>
              <div><span>Latencia de escaneo</span><strong>{formatDuration(selectedChange.scan_processing_time_seconds)}</strong></div>
              <div><span>MTTR</span><strong>{formatDuration(selectedChange.response_time_seconds)}</strong></div>
              <div><span>Coincide con baseline</span><strong>{selectedChange.baseline_match === null ? "Sin baseline aprobada" : selectedChange.baseline_match ? "Sí" : "No"}</strong></div>
              <div><span>Scan run</span><strong>#{selectedChange.scan_run_id}</strong></div>
              <div><span>Webhook</span><strong>{formatStatus(selectedChange.webhook_status)}</strong></div>
              <div><span>Tamaño</span><strong>{selectedChange.size_bytes} bytes</strong></div>
            </div>

            <div className="path-box">
              <span>Ruta completa</span>
              <code>{selectedChange.path}</code>
            </div>

            <div className="hash-grid">
              <div>
                <span>SHA-256 baseline aprobada</span>
                <code title={selectedChange.baseline_sha256}>{shortHash(selectedChange.baseline_sha256)}</code>
              </div>
              <div>
                <span>SHA-256 anterior observado</span>
                <code title={selectedChange.old_sha256}>{shortHash(selectedChange.old_sha256)}</code>
              </div>
              <div>
                <span>SHA-256 nuevo</span>
                <code title={selectedChange.new_sha256}>{shortHash(selectedChange.new_sha256)}</code>
              </div>
              <div>
                <span>MD5 anterior</span>
                <code title={selectedChange.old_md5}>{shortHash(selectedChange.old_md5)}</code>
              </div>
              <div>
                <span>MD5 nuevo</span>
                <code title={selectedChange.new_md5}>{shortHash(selectedChange.new_md5)}</code>
              </div>
            </div>

            {selectedChange.webhook_error && (
              <div className="error-box compact-error">{selectedChange.webhook_error}</div>
            )}

            {(selectedChange.webhook_status === "FAILED" || selectedChange.webhook_status === "NOT_CONFIGURED") && (
              <div className="modal-actions">
                <button onClick={() => retrySelectedWebhook(selectedChange)} disabled={loading} className="secondary">
                  <RefreshCcw size={16} /> Reenviar a n8n
                </button>
              </div>
            )}

            <div className="modal-actions">
              {reviewStatuses.map((status) => (
                <button
                  key={status}
                  className={selectedChange.review_status === status ? "" : "secondary"}
                  onClick={() => updateReviewStatus(selectedChange, status)}
                  disabled={loading}
                >
                  {status === "REVIEWED" && <CheckCircle2 size={16} />}
                  {formatStatus(status)}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
