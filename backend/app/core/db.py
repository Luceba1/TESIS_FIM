from collections.abc import Generator
from sqlalchemy import text
from sqlmodel import SQLModel, Session, create_engine

from app.core.config import get_settings

settings = get_settings()
engine = create_engine(settings.database_url, echo=False, pool_pre_ping=True)


def apply_lightweight_migrations() -> None:
    """Ajustes mínimos para bases ya creadas durante el desarrollo del MVP.

    SQLModel crea tablas nuevas, pero no modifica columnas/enums existentes.
    Para que Lucas pueda actualizar el proyecto sin borrar datos, dejamos acá
    las migraciones pequeñas necesarias para la demo académica.
    """
    with engine.begin() as connection:
        # PostgreSQL enum: requerido si la base viene de una versión anterior.
        connection.execute(text("ALTER TYPE changereviewstatus ADD VALUE IF NOT EXISTS 'FALSE_POSITIVE'"))

        # MTTR: momento en el que el evento fue atendido/revisado por el usuario.
        connection.execute(text("ALTER TABLE file_changes ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ"))


def create_db_and_tables() -> None:
    SQLModel.metadata.create_all(engine)
    apply_lightweight_migrations()


def get_session() -> Generator[Session, None, None]:
    with Session(engine) as session:
        yield session
