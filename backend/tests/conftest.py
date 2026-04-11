import pytest

from app.core.config import _get_settings_cached

TEST_JWT_SECRET_KEY = "test-jwt-secret-key-at-least-32-chars"


@pytest.fixture(autouse=True)
def _clear_settings_cache() -> None:
    """Clear the cached AppSettings before every test so env-var changes take effect."""
    _get_settings_cached.cache_clear()


@pytest.fixture(autouse=True)
def set_test_jwt_secret_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", TEST_JWT_SECRET_KEY)
