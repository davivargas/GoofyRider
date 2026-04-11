from functools import lru_cache
from typing import NoReturn
from urllib.parse import quote_plus

from dotenv import load_dotenv
from pydantic import PositiveInt
from pydantic import ValidationError as PydanticValidationError
from pydantic_settings import BaseSettings
from pydantic_settings import SettingsConfigDict

load_dotenv()


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", str_strip_whitespace=True)

    database_url: str | None = None
    postgres_user: str | None = None
    postgres_password: str | None = None
    postgres_host: str | None = None
    postgres_port: PositiveInt = 5432
    postgres_db: str | None = None

    jwt_secret_key: str | None = None
    jwt_algorithm: str = "HS256"

    access_token_expire_minutes: PositiveInt = 30
    refresh_token_expire_days: PositiveInt = 14

    sqlalchemy_echo: bool = False

    ski_api_base_url: str = "https://api.skiapi.com/v1"
    ski_api_host: str | None = None
    ski_api_key: str | None = None
    ski_api_page_size: PositiveInt = 50
    ski_api_timeout_seconds: PositiveInt = 10

    resort_sync_enabled: bool = True
    resort_sync_interval_days: PositiveInt = 7


def get_database_url() -> str:
    settings = _get_settings()
    if settings.database_url:
        return settings.database_url

    return _build_database_url_from_postgres_env(settings)


def get_jwt_secret_key() -> str:
    secret_key = _get_settings().jwt_secret_key
    if not secret_key:
        raise ValueError("JWT_SECRET_KEY is not set.")

    if len(secret_key) < 32:
        raise ValueError("JWT_SECRET_KEY must be at least 32 characters long.")

    return secret_key


def get_jwt_algorithm() -> str:
    return _get_settings().jwt_algorithm


def get_access_token_expire_minutes() -> int:
    return _get_settings().access_token_expire_minutes


def get_refresh_token_expire_days() -> int:
    return _get_settings().refresh_token_expire_days


def get_sqlalchemy_echo() -> bool:
    return _get_settings().sqlalchemy_echo


def get_ski_api_base_url() -> str:
    normalized = _get_settings().ski_api_base_url.rstrip("/")
    if not normalized:
        raise ValueError("SKI_API_BASE_URL must not be empty.")
    return normalized


def get_ski_api_host() -> str | None:
    return _get_settings().ski_api_host or None


def get_ski_api_key() -> str | None:
    return _get_settings().ski_api_key or None


def get_ski_api_page_size() -> int:
    return _get_settings().ski_api_page_size


def get_ski_api_timeout_seconds() -> int:
    return _get_settings().ski_api_timeout_seconds


def get_resort_sync_enabled() -> bool:
    return _get_settings().resort_sync_enabled


def get_resort_sync_interval_days() -> int:
    return _get_settings().resort_sync_interval_days


def _build_database_url_from_postgres_env(settings: AppSettings) -> str:
    user = settings.postgres_user or ""
    password = settings.postgres_password or ""
    host = settings.postgres_host or ""
    db_name = settings.postgres_db or ""

    if not all([user, password, host, db_name]):
        raise ValueError("DATABASE_URL is not set.")

    port = settings.postgres_port
    encoded_password = quote_plus(password)
    return f"postgresql+psycopg://{user}:{encoded_password}@{host}:{port}/{db_name}"


def _get_settings() -> AppSettings:
    """Build settings, translating Pydantic validation errors into ValueError."""
    try:
        return _get_settings_cached()
    except PydanticValidationError as exc:
        _get_settings_cached.cache_clear()
        _raise_settings_validation_error(exc)


@lru_cache(maxsize=1)
def _get_settings_cached() -> AppSettings:
    return AppSettings()


def _raise_settings_validation_error(exc: PydanticValidationError) -> NoReturn:
    """Translate a Pydantic ValidationError into a human-friendly ValueError."""
    for error in exc.errors():
        field_name = str(error["loc"][0]).upper() if error.get("loc") else "UNKNOWN"
        error_type = error.get("type", "")

        if error_type in {"greater_than", "greater_than_equal"}:
            raise ValueError(
                f"{field_name} must be a positive integer."
            ) from exc
        if error_type in {"int_parsing", "int_type"}:
            raise ValueError(f"{field_name} must be an integer.") from exc
        if error_type in {"bool_parsing", "bool_type"}:
            raise ValueError(f"{field_name} must be a boolean value.") from exc

    raise ValueError(str(exc)) from exc
