import hashlib
from pathlib import Path

from app.core.config import get_settings


def calculate_hashes(file_path: Path, *, include_md5: bool | None = None) -> tuple[str, str]:
    """Calcula SHA-256 y, opcionalmente, MD5 sobre una única lectura del archivo.

    SHA-256 permanece como criterio de integridad. MD5 se conserva únicamente
    como dato auxiliar y puede deshabilitarse mediante CALCULATE_MD5=false.
    Cuando está deshabilitado se devuelve una cadena vacía para mantener el
    contrato histórico tuple[str, str] y la compatibilidad con el esquema.
    """
    if include_md5 is None:
        include_md5 = get_settings().calculate_md5

    sha256 = hashlib.sha256()
    md5 = hashlib.md5() if include_md5 else None

    with file_path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            sha256.update(chunk)
            if md5 is not None:
                md5.update(chunk)

    return sha256.hexdigest(), md5.hexdigest() if md5 is not None else ""
