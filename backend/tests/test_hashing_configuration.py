import hashlib

from app.core.config import get_settings
from app.services.hashing import calculate_hashes


def test_md5_can_be_disabled_without_affecting_sha256(monkeypatch, tmp_path):
    target = tmp_path / "sample.bin"
    payload = b"watchdogs-fim-md5-config"
    target.write_bytes(payload)

    monkeypatch.setenv("CALCULATE_MD5", "false")
    get_settings.cache_clear()
    try:
        sha256, md5 = calculate_hashes(target)
    finally:
        get_settings.cache_clear()

    assert sha256 == hashlib.sha256(payload).hexdigest()
    assert md5 == ""


def test_md5_remains_available_when_enabled(monkeypatch, tmp_path):
    target = tmp_path / "sample.bin"
    payload = b"watchdogs-fim-md5-config"
    target.write_bytes(payload)

    monkeypatch.setenv("CALCULATE_MD5", "true")
    get_settings.cache_clear()
    try:
        sha256, md5 = calculate_hashes(target)
    finally:
        get_settings.cache_clear()

    assert sha256 == hashlib.sha256(payload).hexdigest()
    assert md5 == hashlib.md5(payload).hexdigest()
