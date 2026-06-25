from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.core.db import create_db_and_tables
from app.services.background_monitor import monitor
from app.routers import agent, baseline, changes, environments, metrics, paths, scan, settings as settings_router

app_settings = get_settings()

app = FastAPI(
    title="WatchDogs FIM API",
    description="API para monitoreo automatizado de integridad de archivos.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=app_settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup() -> None:
    create_db_and_tables()
    if app_settings.auto_start_monitor:
        monitor.start()


@app.on_event("shutdown")
def on_shutdown() -> None:
    monitor.stop()


@app.get("/health")
def health():
    return {"status": "ok"}


app.include_router(environments.router, prefix="/api/v1")
app.include_router(paths.router, prefix="/api/v1")
app.include_router(baseline.router, prefix="/api/v1")
app.include_router(scan.router, prefix="/api/v1")
app.include_router(changes.router, prefix="/api/v1")
app.include_router(settings_router.router, prefix="/api/v1")
app.include_router(metrics.router, prefix="/api/v1")
app.include_router(agent.router, prefix="/api/v1")
