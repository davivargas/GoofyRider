import pytest

from app.core.config import get_access_token_expire_minutes
from app.core.config import get_database_url
from app.core.config import get_jwt_secret_key
from app.core.config import get_refresh_token_expire_days
from app.core.config import get_sqlalchemy_echo


def test_get_database_url_raises_when_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("POSTGRES_USER", raising=False)
    monkeypatch.delenv("POSTGRES_PASSWORD", raising=False)
    monkeypatch.delenv("POSTGRES_HOST", raising=False)
    monkeypatch.delenv("POSTGRES_PORT", raising=False)
    monkeypatch.delenv("POSTGRES_DB", raising=False)

    with pytest.raises(ValueError, match="DATABASE_URL is not set."):
        get_database_url()


def test_get_database_url_builds_from_postgres_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("POSTGRES_USER", "app_user")
    monkeypatch.setenv("POSTGRES_PASSWORD", "pass?with:special@chars")
    monkeypatch.setenv("POSTGRES_HOST", "db")
    monkeypatch.setenv("POSTGRES_PORT", "5432")
    monkeypatch.setenv("POSTGRES_DB", "goofyrider")

    assert (
        get_database_url()
        == "postgresql+psycopg://app_user:pass%3Fwith%3Aspecial%40chars@db:5432/goofyrider"
    )


def test_get_database_url_rejects_invalid_postgres_port(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("POSTGRES_USER", "app_user")
    monkeypatch.setenv("POSTGRES_PASSWORD", "secret")
    monkeypatch.setenv("POSTGRES_HOST", "db")
    monkeypatch.setenv("POSTGRES_PORT", "invalid")
    monkeypatch.setenv("POSTGRES_DB", "goofyrider")

    with pytest.raises(ValueError, match="POSTGRES_PORT must be an integer."):
        get_database_url()


def test_get_access_token_expire_minutes_from_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ACCESS_TOKEN_EXPIRE_MINUTES", "45")

    assert get_access_token_expire_minutes() == 45


def test_get_refresh_token_expire_days_rejects_non_integer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("REFRESH_TOKEN_EXPIRE_DAYS", "invalid")

    with pytest.raises(ValueError, match="REFRESH_TOKEN_EXPIRE_DAYS must be an integer."):
        get_refresh_token_expire_days()


def test_get_access_token_expire_minutes_rejects_non_positive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ACCESS_TOKEN_EXPIRE_MINUTES", "0")

    with pytest.raises(
        ValueError,
        match="ACCESS_TOKEN_EXPIRE_MINUTES must be a positive integer.",
    ):
        get_access_token_expire_minutes()


def test_get_sqlalchemy_echo_defaults_to_false(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SQLALCHEMY_ECHO", raising=False)
    assert get_sqlalchemy_echo() is False


def test_get_sqlalchemy_echo_parses_true_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SQLALCHEMY_ECHO", "true")
    assert get_sqlalchemy_echo() is True


def test_get_sqlalchemy_echo_rejects_invalid_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SQLALCHEMY_ECHO", "sometimes")

    with pytest.raises(ValueError, match="SQLALCHEMY_ECHO must be a boolean value."):
        get_sqlalchemy_echo()


def test_get_jwt_secret_key_raises_when_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("JWT_SECRET_KEY", raising=False)

    with pytest.raises(ValueError, match="JWT_SECRET_KEY is not set."):
        get_jwt_secret_key()


def test_get_jwt_secret_key_rejects_short_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", "too-short")

    with pytest.raises(
        ValueError,
        match="JWT_SECRET_KEY must be at least 32 characters long.",
    ):
        get_jwt_secret_key()


def test_get_jwt_secret_key_normalizes_whitespace(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", "  12345678901234567890123456789012  ")

    assert get_jwt_secret_key() == "12345678901234567890123456789012"
