from functools import lru_cache
from typing import NoReturn
from urllib.parse import quote_plus

from dotenv import load_dotenv
from pydantic import PositiveInt
from pydantic import ValidationError as PydanticValidationError
from pydantic import field_validator
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

    session_analyzer_version: str = "analyzer@1"

    @field_validator("jwt_secret_key")
    @classmethod
    def _validate_jwt_secret_key(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if len(value) < 32:
            raise ValueError("JWT_SECRET_KEY must be at least 32 characters long.")
        return value

    @field_validator("ski_api_base_url")
    @classmethod
    def _validate_ski_api_base_url(cls, value: str) -> str:
        normalized = value.rstrip("/")
        if not normalized:
            raise ValueError("SKI_API_BASE_URL must not be empty.")
        return normalized

    @field_validator("ski_api_host", "ski_api_key")
    @classmethod
    def _blank_string_becomes_none(cls, value: str | None) -> str | None:
        if value is None or value == "":
            return None
        return value

    def resolve_database_url(self) -> str:
        if self.database_url:
            return self.database_url

        user = self.postgres_user or ""
        password = self.postgres_password or ""
        host = self.postgres_host or ""
        db_name = self.postgres_db or ""

        if not all([user, password, host, db_name]):
            raise ValueError("DATABASE_URL is not set.")

        encoded_password = quote_plus(password)
        return (
            f"postgresql+psycopg://{user}:{encoded_password}@{host}:{self.postgres_port}/{db_name}"
        )

    def require_jwt_secret_key(self) -> str:
        if not self.jwt_secret_key:
            raise ValueError("JWT_SECRET_KEY is not set.")
        return self.jwt_secret_key


@lru_cache(maxsize=1)
def get_settings() -> AppSettings:
    try:
        return AppSettings()
    except PydanticValidationError as exc:
        get_settings.cache_clear()
        _raise_settings_validation_error(exc)


def get_database_url() -> str:
    return get_settings().resolve_database_url()


def _raise_settings_validation_error(exc: PydanticValidationError) -> NoReturn:
    for error in exc.errors():
        field_name = str(error["loc"][0]).upper() if error.get("loc") else "UNKNOWN"
        error_type = error.get("type", "")

        if error_type == "value_error":
            message = error.get("msg", "")
            prefix = "Value error, "
            if message.startswith(prefix):
                raise ValueError(message[len(prefix) :]) from exc
            raise ValueError(message) from exc
        if error_type in {"greater_than", "greater_than_equal"}:
            raise ValueError(f"{field_name} must be a positive integer.") from exc
        if error_type in {"int_parsing", "int_type"}:
            raise ValueError(f"{field_name} must be an integer.") from exc
        if error_type in {"bool_parsing", "bool_type"}:
            raise ValueError(f"{field_name} must be a boolean value.") from exc

    raise ValueError(str(exc)) from exc
