import pytest

from app.core.config import get_database_url
from app.core.config import get_settings


def test_get_database_url_raises_when_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("POSTGRES_USER", raising=False)
    monkeypatch.delenv("POSTGRES_PASSWORD", raising=False)
    monkeypatch.delenv("POSTGRES_HOST", raising=False)
    monkeypatch.delenv("POSTGRES_PORT", raising=False)
    monkeypatch.delenv("POSTGRES_DB", raising=False)

    with pytest.raises(ValueError, match=r"DATABASE_URL is not set."):
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

    with pytest.raises(ValueError, match=r"POSTGRES_PORT must be an integer."):
        get_database_url()


def test_access_token_expire_minutes_from_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ACCESS_TOKEN_EXPIRE_MINUTES", "45")

    assert get_settings().access_token_expire_minutes == 45


def test_refresh_token_expire_days_rejects_non_integer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("REFRESH_TOKEN_EXPIRE_DAYS", "invalid")

    with pytest.raises(ValueError, match=r"REFRESH_TOKEN_EXPIRE_DAYS must be an integer."):
        get_settings()


def test_access_token_expire_minutes_rejects_non_positive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ACCESS_TOKEN_EXPIRE_MINUTES", "0")

    with pytest.raises(
        ValueError,
        match=r"ACCESS_TOKEN_EXPIRE_MINUTES must be a positive integer.",
    ):
        get_settings()


def test_sqlalchemy_echo_defaults_to_false(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SQLALCHEMY_ECHO", raising=False)
    assert get_settings().sqlalchemy_echo is False


def test_sqlalchemy_echo_parses_true_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SQLALCHEMY_ECHO", "true")
    assert get_settings().sqlalchemy_echo is True


def test_sqlalchemy_echo_rejects_invalid_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SQLALCHEMY_ECHO", "sometimes")

    with pytest.raises(ValueError, match=r"SQLALCHEMY_ECHO must be a boolean value."):
        get_settings()


def test_require_jwt_secret_key_raises_when_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("JWT_SECRET_KEY", raising=False)

    with pytest.raises(ValueError, match=r"JWT_SECRET_KEY is not set."):
        get_settings().require_jwt_secret_key()


def test_jwt_secret_key_rejects_short_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", "too-short")

    with pytest.raises(
        ValueError,
        match=r"JWT_SECRET_KEY must be at least 32 characters long.",
    ):
        get_settings()


def test_jwt_secret_key_normalizes_whitespace(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("JWT_SECRET_KEY", "  12345678901234567890123456789012  ")

    assert get_settings().jwt_secret_key == "12345678901234567890123456789012"


def test_ski_api_base_url_normalizes_trailing_slash(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SKI_API_BASE_URL", " https://api.skiapi.com/v1/ ")

    assert get_settings().ski_api_base_url == "https://api.skiapi.com/v1"


def test_ski_api_key_returns_none_when_blank(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SKI_API_KEY", "   ")

    assert get_settings().ski_api_key is None


def test_ski_api_page_size_rejects_non_positive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SKI_API_PAGE_SIZE", "0")

    with pytest.raises(ValueError, match=r"SKI_API_PAGE_SIZE must be a positive integer."):
        get_settings()


def test_ski_api_timeout_seconds_from_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SKI_API_TIMEOUT_SECONDS", "25")

    assert get_settings().ski_api_timeout_seconds == 25


def test_ski_api_host_returns_none_when_blank(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SKI_API_HOST", "   ")

    assert get_settings().ski_api_host is None


def test_debug_defaults_to_false(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DEBUG", raising=False)

    assert get_settings().debug is False


def test_security_setting_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "ACCESS_TOKEN_EXPIRE_MINUTES",
        "REFRESH_TOKEN_EXPIRE_DAYS",
        "REFRESH_TOKEN_FAMILY_MAX_DAYS",
        "RATE_LIMIT_LOGIN_PER_IP",
        "MAX_POINTS_PER_SESSION",
    ):
        monkeypatch.delenv(name, raising=False)

    settings = get_settings()

    assert settings.access_token_expire_minutes == 15
    assert settings.refresh_token_expire_days == 30
    assert settings.refresh_token_family_max_days == 90
    assert settings.jwt_issuer == "fall-line-api"
    assert settings.jwt_audience == "fall-line-mobile"
    assert settings.rate_limit_enabled is True
    assert settings.rate_limit_login_per_ip == 10
    assert settings.rate_limit_login_per_email == 5
    assert settings.rate_limit_register_per_ip == 5
    assert settings.rate_limit_refresh_per_ip == 30
    assert settings.rate_limit_window_seconds == 300
    assert settings.rate_limit_register_window_seconds == 3600
    assert settings.trust_proxy_headers is False
    assert settings.max_points_per_session == 200000


def test_refresh_family_cap_must_cover_refresh_lifetime(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("REFRESH_TOKEN_EXPIRE_DAYS", "40")
    monkeypatch.setenv("REFRESH_TOKEN_FAMILY_MAX_DAYS", "30")

    with pytest.raises(
        ValueError,
        match=r"REFRESH_TOKEN_FAMILY_MAX_DAYS must be >= REFRESH_TOKEN_EXPIRE_DAYS.",
    ):
        get_settings()


def test_rate_limit_setting_parses_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("RATE_LIMIT_LOGIN_PER_IP", "3")

    assert get_settings().rate_limit_login_per_ip == 3


def test_openskidata_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OPENSKIDATA_BASE_URL", raising=False)
    monkeypatch.delenv("OPENSKIDATA_TIMEOUT_SECONDS", raising=False)

    settings = get_settings()

    assert settings.openskidata_base_url == "https://tiles.openskimap.org"
    assert settings.openskidata_timeout_seconds == 120


def test_openskidata_base_url_strips_trailing_slash(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENSKIDATA_BASE_URL", "https://mirror.example/data/")

    assert get_settings().openskidata_base_url == "https://mirror.example/data"


def test_openskidata_base_url_rejects_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENSKIDATA_BASE_URL", "/")

    with pytest.raises(ValueError, match=r"OPENSKIDATA_BASE_URL must not be empty."):
        get_settings()


def test_openskidata_timeout_rejects_non_positive(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENSKIDATA_TIMEOUT_SECONDS", "0")

    with pytest.raises(
        ValueError, match=r"OPENSKIDATA_TIMEOUT_SECONDS must be a positive integer."
    ):
        get_settings()


def test_removed_sync_settings_are_ignored(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("RESORT_SYNC_ENABLED", "true")
    monkeypatch.setenv("OVERPASS_BASE_URL", "https://overpass.example")

    settings = get_settings()

    assert not hasattr(settings, "resort_sync_enabled")
    assert not hasattr(settings, "overpass_base_url")
