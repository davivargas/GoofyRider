import pytest

from app.core.config import get_settings

TEST_JWT_SECRET_KEY = "test-jwt-secret-key-at-least-32-chars"


@pytest.fixture(autouse=True)
def _clear_settings_cache() -> None:
    """Clear the cached AppSettings before every test so env-var changes take effect."""
    get_settings.cache_clear()


@pytest.fixture(autouse=True)
def set_test_jwt_secret_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", TEST_JWT_SECRET_KEY)


@pytest.fixture(autouse=True)
def _fast_argon2(monkeypatch: pytest.MonkeyPatch) -> None:
    """Argon2id at production cost takes ~150 ms per hash; tests use a small profile."""
    monkeypatch.setenv("ARGON2_MEMORY_KIB", "8192")
    monkeypatch.setenv("ARGON2_TIME_COST", "1")
    monkeypatch.setenv("ARGON2_PARALLELISM", "1")
