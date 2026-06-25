from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    database_url: str = "postgresql+psycopg://fim_user:fim_password@localhost:5432/watchdogs_fim"
    backend_cors_origins: str = "http://localhost:5173,http://127.0.0.1:5173"
    scan_interval_seconds: int = 10
    n8n_webhook_url: str = ""
    auto_start_monitor: bool = True

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def cors_origins(self) -> list[str]:
        return [origin.strip() for origin in self.backend_cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
