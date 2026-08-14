from collections.abc import Generator

from sqlalchemy import text
from sqlmodel import SQLModel, Session, create_engine

from app.core.config import get_settings

settings = get_settings()
engine = create_engine(settings.database_url, echo=False, pool_pre_ping=True)


# Columnas temporales del modelo que deben conservar offset de zona horaria en
# PostgreSQL. Las bases creadas por versiones antiguas de SQLModel podían haber
# quedado como TIMESTAMP WITHOUT TIME ZONE aunque la aplicación generara UTC.
_TIMEZONE_COLUMNS: dict[str, tuple[str, ...]] = {
    "environments": ("created_at",),
    "monitored_paths": ("created_at",),
    "file_hashes": (
        "last_modified",
        "baseline_approved_at",
        "observed_last_modified",
        "last_seen_at",
        "updated_at",
    ),
    "scan_runs": ("started_at", "finished_at"),
    "file_changes": ("occurred_at", "detected_at", "reviewed_at"),
    "app_settings": ("updated_at",),
    "agent_heartbeat": ("last_seen_at",),
}


def _convert_legacy_timestamp_columns(connection) -> None:
    """Convierte timestamps legacy a TIMESTAMPTZ sin cambiar el instante real.

    Las versiones anteriores almacenaban algunas fechas como ``timestamp without
    time zone``. PostgreSQL devolvía entonces un ``datetime`` ingenuo y el backend
    no podía distinguir, por ejemplo, 02:16 hora local de 02:16 UTC. Al comparar
    ese valor con ``occurred_at`` (que sí era TIMESTAMPTZ) el MTTD podía quedar
    negativo y terminar truncado a 0.

    Para migrar datos existentes se interpreta cada valor ingenuo usando la zona
    horaria activa de la sesión de PostgreSQL. Esto conserva el instante que el
    servidor venía mostrando antes de la migración. La operación es idempotente:
    solo actúa sobre columnas que todavía sean ``timestamp without time zone``.
    """
    for table_name, columns in _TIMEZONE_COLUMNS.items():
        for column_name in columns:
            data_type = connection.execute(
                text(
                    """
                    SELECT data_type
                    FROM information_schema.columns
                    WHERE table_schema = current_schema()
                      AND table_name = :table_name
                      AND column_name = :column_name
                    """
                ),
                {"table_name": table_name, "column_name": column_name},
            ).scalar_one_or_none()

            if data_type != "timestamp without time zone":
                continue

            # Los identificadores provienen exclusivamente de la constante
            # _TIMEZONE_COLUMNS, no de entrada del usuario.
            connection.execute(
                text(
                    f'ALTER TABLE "{table_name}" '
                    f'ALTER COLUMN "{column_name}" TYPE TIMESTAMPTZ '
                    f'USING "{column_name}" AT TIME ZONE current_setting(\'TimeZone\')'
                )
            )


def apply_lightweight_migrations() -> None:
    """Migraciones pequeñas para actualizar bases del MVP sin perder evidencia.

    El proyecto todavía no usa Alembic. Estas sentencias mantienen compatible una
    base creada con versiones anteriores y reflejan el esquema documentado en
    ``database/schema.sql``.
    """
    with engine.begin() as connection:
        # PostgreSQL enums creados por SQLModel en instalaciones previas.
        connection.execute(text("ALTER TYPE changereviewstatus ADD VALUE IF NOT EXISTS 'FALSE_POSITIVE'"))
        connection.execute(text("ALTER TYPE scanstatus ADD VALUE IF NOT EXISTS 'PARTIAL'"))

        # MTTR / revisión.
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ"))

        # MTTD real y trazabilidad contra la línea base.
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS occurred_at TIMESTAMPTZ"))
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS occurred_at_source TEXT NOT NULL DEFAULT 'UNKNOWN'"))
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS baseline_sha256 TEXT NOT NULL DEFAULT ''"))
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS baseline_md5 TEXT NOT NULL DEFAULT ''"))
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS baseline_match BOOLEAN"))

        # Separación entre línea base aprobada y último estado observado.
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS observed_sha256 TEXT NOT NULL DEFAULT ''"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS observed_md5 TEXT NOT NULL DEFAULT ''"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS observed_size_bytes BIGINT NOT NULL DEFAULT 0"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS observed_last_modified TIMESTAMPTZ"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS baseline_approved BOOLEAN NOT NULL DEFAULT TRUE"))
        connection.execute(text("ALTER TABLE file_hashes ADD COLUMN IF NOT EXISTS baseline_approved_at TIMESTAMPTZ"))

        # Escaneos parciales: un archivo ilegible ya no aborta todo el ciclo.
        connection.execute(text("ALTER TABLE scan_runs ADD COLUMN IF NOT EXISTS files_skipped INTEGER NOT NULL DEFAULT 0"))
        connection.execute(text("ALTER TABLE scan_runs ADD COLUMN IF NOT EXISTS warning_message TEXT NOT NULL DEFAULT ''"))

        # Corrige el problema de zonas horarias de las bases creadas con el
        # modelo anterior. Debe ejecutarse antes de usar esas marcas en métricas.
        _convert_legacy_timestamp_columns(connection)

        # Inicializa el estado observado de filas preexistentes sin alterar su baseline.
        connection.execute(
            text(
                """
                UPDATE file_hashes
                SET observed_sha256 = sha256,
                    observed_md5 = md5,
                    observed_size_bytes = size_bytes,
                    observed_last_modified = last_modified,
                    last_seen_at = COALESCE(last_seen_at, updated_at),
                    baseline_approved_at = CASE
                        WHEN baseline_approved THEN COALESCE(baseline_approved_at, updated_at)
                        ELSE NULL
                    END
                WHERE observed_sha256 = ''
                """
            )
        )

        # Invariante de dominio: si una fila NO está aprobada como baseline, no
        # puede tener fecha de aprobación. Corrige filas generadas por versiones
        # anteriores donde el default de Python completaba la fecha igualmente.
        connection.execute(
            text(
                """
                UPDATE file_hashes
                SET baseline_approved_at = NULL
                WHERE baseline_approved = FALSE
                  AND baseline_approved_at IS NOT NULL
                """
            )
        )


def create_db_and_tables() -> None:
    SQLModel.metadata.create_all(engine)
    apply_lightweight_migrations()


def get_session() -> Generator[Session, None, None]:
    with Session(engine) as session:
        yield session
