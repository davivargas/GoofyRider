import os

from dotenv import load_dotenv

load_dotenv()


def get_database_url() -> str:
    database_url = os.getenv("DATABASE_URL")

    if not database_url:
        raise ValueError("DATABASE_URL is not set.")

    return database_url


def get_jwt_secret_key() -> str:
    secret_key = os.getenv("JWT_SECRET_KEY")
    if secret_key is None:
        raise ValueError("JWT_SECRET_KEY is not set.")

    normalized = secret_key.strip()
    if not normalized:
        raise ValueError("JWT_SECRET_KEY is not set.")

    if len(normalized) < 32:
        raise ValueError("JWT_SECRET_KEY must be at least 32 characters long.")

    return normalized


def get_jwt_algorithm() -> str:
    return os.getenv("JWT_ALGORITHM", "HS256")


def get_access_token_expire_minutes() -> int:
    return _get_positive_int("ACCESS_TOKEN_EXPIRE_MINUTES", default=30)


def get_refresh_token_expire_days() -> int:
    return _get_positive_int("REFRESH_TOKEN_EXPIRE_DAYS", default=14)


def get_sqlalchemy_echo() -> bool:
    raw_value = os.getenv("SQLALCHEMY_ECHO")
    if raw_value is None:
        return False

    normalized = raw_value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False

    raise ValueError("SQLALCHEMY_ECHO must be a boolean value.")


def _get_positive_int(env_name: str, default: int) -> int:
    raw_value = os.getenv(env_name)
    if raw_value is None:
        return default

    try:
        parsed = int(raw_value)
    except ValueError as exc:
        raise ValueError(f"{env_name} must be an integer.") from exc

    if parsed <= 0:
        raise ValueError(f"{env_name} must be a positive integer.")

    return parsed
