from urllib.parse import quote_plus
from typing import cast

from dotenv import load_dotenv
from pydantic import PositiveInt
from pydantic import TypeAdapter
from pydantic import ValidationError as PydanticValidationError
from pydantic_settings import BaseSettings
from pydantic_settings import SettingsConfigDict

load_dotenv()

BOOL_ADAPTER: TypeAdapter[bool] = TypeAdapter(bool)
POSITIVE_INT_ADAPTER: TypeAdapter[int] = cast(TypeAdapter[int], TypeAdapter(PositiveInt))


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", str_strip_whitespace=True)

    database_url: str | None = None
    postgres_user: str | None = None
    postgres_password: str | None = None
    postgres_host: str | None = None
    postgres_port: str | None = None
    postgres_db: str | None = None

    jwt_secret_key: str | None = None
    jwt_algorithm: str = "HS256"

    access_token_expire_minutes: str | None = None
    refresh_token_expire_days: str | None = None

    sqlalchemy_echo: str | bool | None = None

    ski_api_base_url: str = "https://api.skiapi.com/v1"
    ski_api_host: str | None = None
    ski_api_key: str | None = None
    ski_api_page_size: str | None = None
    ski_api_timeout_seconds: str | None = None

    resort_sync_enabled: str | bool | None = None
    resort_sync_interval_days: str | None = None


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
    return _parse_positive_int(
        _get_settings().access_token_expire_minutes,
        env_name="ACCESS_TOKEN_EXPIRE_MINUTES",
        default=30,
    )


def get_refresh_token_expire_days() -> int:
    return _parse_positive_int(
        _get_settings().refresh_token_expire_days,
        env_name="REFRESH_TOKEN_EXPIRE_DAYS",
        default=14,
    )


def get_sqlalchemy_echo() -> bool:
    raw_value = _get_settings().sqlalchemy_echo
    if raw_value is None:
        return False

    return _parse_boolean(raw_value, env_name="SQLALCHEMY_ECHO")


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
    return _parse_positive_int(
        _get_settings().ski_api_page_size,
        env_name="SKI_API_PAGE_SIZE",
        default=50,
    )


def get_ski_api_timeout_seconds() -> int:
    return _parse_positive_int(
        _get_settings().ski_api_timeout_seconds,
        env_name="SKI_API_TIMEOUT_SECONDS",
        default=10,
    )


def get_resort_sync_enabled() -> bool:
    raw_value = _get_settings().resort_sync_enabled
    if raw_value is None:
        return True

    return _parse_boolean(raw_value, env_name="RESORT_SYNC_ENABLED")


def get_resort_sync_interval_days() -> int:
    return _parse_positive_int(
        _get_settings().resort_sync_interval_days,
        env_name="RESORT_SYNC_INTERVAL_DAYS",
        default=7,
    )


def _build_database_url_from_postgres_env(settings: AppSettings) -> str:
    user = settings.postgres_user or ""
    password = settings.postgres_password or ""
    host = settings.postgres_host or ""
    db_name = settings.postgres_db or ""

    if not all([user, password, host, db_name]):
        raise ValueError("DATABASE_URL is not set.")

    port = _parse_positive_int(settings.postgres_port, env_name="POSTGRES_PORT", default=5432)
    encoded_password = quote_plus(password)
    return f"postgresql+psycopg://{user}:{encoded_password}@{host}:{port}/{db_name}"


def _get_settings() -> AppSettings:
    return AppSettings()


def _parse_boolean(raw_value: object, *, env_name: str) -> bool:
    try:
        return BOOL_ADAPTER.validate_python(raw_value)
    except PydanticValidationError as exc:
        raise ValueError(f"{env_name} must be a boolean value.") from exc


def _parse_positive_int(raw_value: object, *, env_name: str, default: int) -> int:
    if raw_value is None:
        return default

    try:
        return int(POSITIVE_INT_ADAPTER.validate_python(raw_value))
    except PydanticValidationError as exc:
        if _is_positive_constraint_error(exc):
            raise ValueError(f"{env_name} must be a positive integer.") from exc
        raise ValueError(f"{env_name} must be an integer.") from exc


def _is_positive_constraint_error(exc: PydanticValidationError) -> bool:
    for error in exc.errors():
        if error.get("type") in {"greater_than", "greater_than_equal"}:
            return True
    return False
