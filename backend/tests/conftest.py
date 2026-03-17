import pytest

TEST_JWT_SECRET_KEY = "test-jwt-secret-key-at-least-32-chars"


@pytest.fixture(autouse=True)
def set_test_jwt_secret_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", TEST_JWT_SECRET_KEY)
