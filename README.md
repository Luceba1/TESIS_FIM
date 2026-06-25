# WatchDogs FIM - MVP de Tesis

Prototipo de Monitoreo de Integridad de Archivos para Windows.

Esta versión incorpora **entornos controlados de monitoreo**. Un entorno es un conjunto lógico de rutas críticas con nombre propio, descripción y criticidad. Por ejemplo: `Sistema Académico`, `Backups`, `Documentación Legal` o `Scripts Críticos`.

Cuando ocurre un evento, la alerta incluye el nombre del entorno afectado:

```txt
Alerta en entorno Sistema Académico: MODIFIED en C:\Universidad\SistemaAcademico\config\config.json
```

## Qué incluye

- Backend FastAPI.
- Motor FIM en Python.
- PostgreSQL como base de evidencia.
- Frontend React/Vite con dashboard visual.
- Entornos controlados con rutas asociadas.
- Detección de eventos `CREATED`, `MODIFIED` y `DELETED`.
- Integración con n8n mediante webhook.
- Agente en segundo plano ejecutable por consola o tarea programada de Windows.
- Docker Compose solo para PostgreSQL.

## Estructura

```txt
watchdogs_fim_mvp/
  backend/
    app/
      agent.py
      main.py
      models/
      routers/
      services/
  frontend/
  database/
  n8n/
  docs/
```

## Puesta en marcha rápida

### 1. Levantar PostgreSQL

```bash
docker compose up -d
```

### 2. Backend

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
uvicorn app.main:app --reload
```

Swagger:

```txt
http://127.0.0.1:8000/docs
```

### 3. Frontend

```bash
cd frontend
npm install
npm run dev
```

Panel:

```txt
http://127.0.0.1:5173
```

### 4. Agente de monitoreo

En otra terminal:

```bash
cd backend
.venv\Scripts\activate
python -m app.agent  # opcional: el backend ya puede iniciar el monitor automáticamente
```

## Flujo de demostración recomendado

1. Entrar al panel.
2. Crear un entorno, por ejemplo: `Sistema Académico`.
3. Seleccionar el entorno creado.
4. Agregar una ruta, por ejemplo: `C:\fim_demo\monitoreado`.
5. Generar línea base.
6. Iniciar el agente o ejecutar `Escanear ahora`.
7. Crear un archivo dentro de la carpeta.
8. Modificar un archivo.
9. Eliminar un archivo.
10. Ver eventos en el panel, comprobando que cada evento mencione el entorno afectado.
11. Configurar webhook de n8n para recibir eventos contextualizados.

## Endpoints principales

```txt
GET    /api/v1/environments
POST   /api/v1/environments
PATCH  /api/v1/environments/{environment_id}

GET    /api/v1/paths?environment_id=1
POST   /api/v1/paths
PATCH  /api/v1/paths/{path_id}

POST   /api/v1/baseline/generate?environment_id=1
POST   /api/v1/scan-runs/run?environment_id=1
GET    /api/v1/changes?environment_id=1
GET    /api/v1/metrics
```

## Inicio automático en Windows

Para la tesis se recomienda usar **Tarea Programada de Windows** o **Servicio de Windows**.  
El sistema debe ser silencioso, administrable y auditable, no encubierto.

Ver `docs/windows_startup.md`.

## Evidencias para anexos

- Captura del panel con entornos creados.
- Captura del panel con eventos por entorno.
- Captura de PostgreSQL con `environments`, `monitored_paths` y `file_changes`.
- Captura de n8n recibiendo webhook con `environment_name`.
- Matriz de pruebas manual vs automatizada.
- README de reproducción.


## Monitoreo automático sin consola adicional

Esta versión incluye un monitor en segundo plano integrado al backend. Con `AUTO_START_MONITOR=true` en `backend/.env`, al levantar FastAPI también se inicia el escaneo automático de todos los entornos activos.

Ya no es obligatorio abrir otra terminal para ejecutar `python -m app.agent`. Ese comando queda como alternativa manual o para pruebas aisladas.

Endpoints útiles:

```txt
GET  /api/v1/agent/status
POST /api/v1/agent/start
POST /api/v1/agent/stop
```

El panel muestra el estado del monitor y permite verificar el último heartbeat.


## Inicio automático con Windows

Esta versión incluye scripts para ejecutar el backend/agente como **Tarea Programada de Windows**.

El navegador no se inicia automáticamente. El navegador solo muestra el panel. Lo que se inicia con Windows es el backend, que contiene el monitor FIM en segundo plano.

Para instalar la tarea programada:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install_watchdogs_task.ps1
```

Para iniciarla manualmente sin reiniciar:

```powershell
Start-ScheduledTask -TaskName "WatchDogs FIM Agent"
```

Para desinstalarla:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\uninstall_watchdogs_task.ps1
```

Los logs se guardan en:

```txt
logs/watchdogs_backend.log
```

Para la tesis, esta solución representa la etapa de prototipo. Como trabajo futuro se propone crear un instalador `.exe` que registre el agente como Servicio de Windows.


## Exportación de evidencia

El panel de eventos incluye un botón **Exportar evidencia CSV**. La exportación respeta los filtros activos de entorno, tipo de evento y estado de revisión, e incluye datos útiles para anexos de la tesis: entorno, criticidad, tipo de evento, ruta completa, hashes anteriores/nuevos, fecha de detección, estado de revisión, scan asociado y estado del webhook.

## Integración n8n mejorada

El panel permite configurar la URL del webhook de n8n, probar la conexión y reenviar eventos que hayan fallado.

Endpoints útiles:

```txt
GET  /api/v1/settings/webhook
PUT  /api/v1/settings/webhook
GET  /api/v1/settings/webhook/status
POST /api/v1/settings/webhook/test
POST /api/v1/settings/webhook/retry-failed
```

Flujo recomendado en n8n:

```txt
Webhook (POST) → Respond to Webhook
```

En el nodo Webhook, configurar la respuesta como:

```txt
Respond: Using 'Respond to Webhook' Node
```

El botón **Probar conexión** envía un payload de prueba con `type: TEST`. Los eventos reales envían un payload con `type: FILE_INTEGRITY_EVENT`, incluyendo entorno, criticidad, archivo, ruta, hashes, fecha de detección y estado de revisión.
