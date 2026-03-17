import os

from dotenv import load_dotenv

load_dotenv()


def get_database_url() -> str:
    database_url = os.getenv("DATABASE_URL")

    if not database_url:
        raise ValueError("DATABASE_URL is not set.")

    return database_url


def get_jwt_secret_key() -> str:
    return os.getenv("JWT_SECRET_KEY", "dev-jwt-secret-change-me")


def get_jwt_algorithm() -> str:
    return os.getenv("JWT_ALGORITHM", "HS256")


def get_access_token_expire_minutes() -> int:
    return _get_positive_int("ACCESS_TOKEN_EXPIRE_MINUTES", default=30)


def get_refresh_token_expire_days() -> int:
    return _get_positive_int("REFRESH_TOKEN_EXPIRE_DAYS", default=14)


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
