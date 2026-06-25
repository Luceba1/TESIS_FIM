import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Activity,
  AlertTriangle,
  BellRing,
  Database,
  FolderCog,
  FolderPlus,
  Play,
  ShieldCheck,
} from "lucide-react";
import { api, AgentStatus, Environment, FileChange, Metrics, MonitoredPath } from "./api/client";
import "./styles.css";

const criticalities = ["LOW", "MEDIUM", "HIGH", "CRITICAL"];

function StatCard({ title, value, icon }: { title: string; value: string | number; icon: React.ReactNode }) {
  return (
    <div className="card stat-card">
      <div>
        <p className="muted">{title}</p>
        <h2>{value}</h2>
      </div>
      <div className="icon-box">{icon}</div>
    </div>
  );
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

function App() {
  const [metrics, setMetrics] = useState<Metrics | null>(null);
  const [environments, setEnvironments] = useState<Environment[]>([]);
  const [paths, setPaths] = useState<MonitoredPath[]>([]);
  const [changes, setChanges] = useState<FileChange[]>([]);
  const [selectedEnvironmentId, setSelectedEnvironmentId] = useState<number | "all">("all");
  const [newEnvironmentName, setNewEnvironmentName] = useState("");
  const [newEnvironmentDescription, setNewEnvironmentDescription] = useState("");
  const [newEnvironmentCriticality, setNewEnvironmentCriticality] = useState("HIGH");
  const [newPath, setNewPath] = useState("");
  const [webhook, setWebhook] = useState("");
  const [agentStatus, setAgentStatus] = useState<AgentStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const selectedEnvironment = useMemo(
    () => environments.find((item) => item.id === selectedEnvironmentId),
    [environments, selectedEnvironmentId]
  );

  async function loadData() {
    const query = selectedEnvironmentId === "all" ? "" : `?environment_id=${selectedEnvironmentId}`;
    const [metricsData, environmentsData, pathsData, changesData, webhookData, agentData] = await Promise.all([
      api<Metrics>("/metrics"),
      api<Environment[]>("/environments"),
      api<MonitoredPath[]>(`/paths${query}`),
      api<FileChange[]>(`/changes${query}`),
      api<{ value: string }>("/settings/webhook"),
      api<AgentStatus>("/agent/status"),
    ]);
    setMetrics(metricsData);
    setEnvironments(environmentsData);
    setPaths(pathsData);
    setChanges(changesData);
    setWebhook(webhookData.value ?? "");
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
    });
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
            Entornos controlados para monitorear archivos críticos, detectar cambios y emitir alertas contextualizadas.
          </p>
        </div>
        <div className="system-state">
          <span className="pulse"></span>
          Sistema activo
        </div>
      </section>

      {error && <div className="error-box">{error}</div>}

      <section className="grid stats">
        <StatCard title="Entornos" value={metrics?.environments ?? "-"} icon={<FolderCog />} />
        <StatCard title="Rutas monitoreadas" value={metrics?.monitored_paths ?? "-"} icon={<FolderPlus />} />
        <StatCard title="Archivos activos" value={metrics?.active_files ?? "-"} icon={<Database />} />
        <StatCard title="Alertas críticas hoy" value={metrics?.critical_events_today ?? "-"} icon={<BellRing />} />
      </section>

      <section className="grid two-columns">
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
              placeholder="Ej: C:\\fim_demo\\monitoreado"
              disabled={selectedEnvironmentId === "all"}
            />
            <button onClick={createPath} disabled={loading || selectedEnvironmentId === "all"}>Agregar ruta</button>
          </div>
          {selectedEnvironmentId === "all" && <p className="hint">Seleccioná un entorno para agregarle rutas.</p>}

          <div className="actions">
            <button className="secondary" onClick={generateBaseline} disabled={loading}>Generar línea base</button>
            <button className="secondary" onClick={runScan} disabled={loading}><Play size={16} /> Escanear ahora</button>
          </div>

          <div className="list">
            {paths.map((item) => (
              <div key={item.id} className="list-item">
                <div>
                  <strong>{item.path}</strong>
                  <p className="muted">Criticidad: {item.criticality} · Recursivo: {item.recursive ? "Sí" : "No"}</p>
                </div>
                <span className={item.enabled ? "badge active" : "badge disabled"}>{item.enabled ? "Activa" : "Inactiva"}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="grid two-columns">
        <div className="card">
          <div className="section-header">
            <div>
              <h2>Estado del agente</h2>
              <p className="muted">Proceso de monitoreo en segundo plano.</p>
            </div>
            <Activity />
          </div>
          <div className="agent-box">
            <p><strong>Monitor automático:</strong> <span className={agentStatus?.running ? "badge active" : "badge disabled"}>{agentStatus?.running ? "Activo" : "Detenido"}</span></p>
            <p><strong>Intervalo:</strong> {agentStatus?.interval_seconds ?? "-"} segundos</p>
            <p><strong>Último escaneo:</strong> {agentStatus?.last_scan_at ? new Date(agentStatus.last_scan_at).toLocaleString() : (metrics?.last_scan_at ? new Date(metrics.last_scan_at).toLocaleString() : "Sin datos")}</p>
            <p><strong>Mensaje:</strong> {agentStatus?.message ?? metrics?.last_scan_status ?? "Sin datos"}</p>
            <p><strong>Heartbeat:</strong> {metrics?.agent_last_seen_at ? new Date(metrics.agent_last_seen_at).toLocaleString() : "Agente no iniciado"}</p>
            <p><strong>Eventos hoy:</strong> {metrics?.events_today ?? 0} · <strong>Pendientes:</strong> {metrics?.pending_events ?? 0}</p>
            {agentStatus?.last_error && <p className="error-text"><strong>Último error:</strong> {agentStatus.last_error}</p>}
            <div className="actions">
              <button className="secondary" onClick={startAgent} disabled={loading || agentStatus?.running}>Iniciar monitor</button>
              <button className="secondary danger" onClick={stopAgent} disabled={loading || !agentStatus?.running}>Detener monitor</button>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="section-header">
            <div>
              <h2>Webhook n8n</h2>
              <p className="muted">Las alertas incluyen el nombre del entorno afectado.</p>
            </div>
            <BellRing />
          </div>
          <div className="form-row">
            <input value={webhook} onChange={(e) => setWebhook(e.target.value)} placeholder="URL webhook de n8n" />
            <button onClick={saveWebhook} disabled={loading}>Guardar</button>
          </div>
        </div>
      </section>

      <section className="card">
        <div className="section-header">
          <div>
            <h2>Últimos eventos detectados</h2>
            <p className="muted">Cada alerta indica qué entorno fue afectado.</p>
          </div>
          <AlertTriangle />
        </div>

        <div className="table">
          <div className="table-row table-head">
            <span>Entorno</span>
            <span>Evento</span>
            <span>Archivo</span>
            <span>Detectado</span>
            <span>Estado</span>
            <span>n8n</span>
          </div>
          {changes.map((change) => (
            <div className="table-row" key={change.id}>
              <span><strong>{change.environment_name}</strong></span>
              <span className={eventClass(change.event_type)}>{eventLabel(change.event_type)}</span>
              <span className="path-cell">{change.path}</span>
              <span>{new Date(change.detected_at).toLocaleString()}</span>
              <span>{change.review_status}</span>
              <span>{change.webhook_status}</span>
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
