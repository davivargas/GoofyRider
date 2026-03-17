import base64
import hashlib
import hmac
import secrets
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from typing import Any

import jwt
from jwt import ExpiredSignatureError
from jwt import InvalidTokenError

from app.core.config import get_access_token_expire_minutes
from app.core.config import get_jwt_algorithm
from app.core.config import get_jwt_secret_key
from app.core.config import get_refresh_token_expire_days

TOKEN_TYPE_ACCESS = "access"
TOKEN_TYPE_REFRESH = "refresh"
PASSWORD_HASH_ALGORITHM = "pbkdf2_sha256"
PASSWORD_HASH_ITERATIONS = 390000
SALT_BYTES = 16
KEY_BYTES = 32


class TokenValidationError(Exception):
    pass


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(SALT_BYTES)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        PASSWORD_HASH_ITERATIONS,
        dklen=KEY_BYTES,
    )
    salt_b64 = base64.b64encode(salt).decode("ascii")
    digest_b64 = base64.b64encode(digest).decode("ascii")
    return (
        f"{PASSWORD_HASH_ALGORITHM}"
        f"${PASSWORD_HASH_ITERATIONS}"
        f"${salt_b64}"
        f"${digest_b64}"
    )


def verify_password(password: str, stored_password_hash: str) -> bool:
    try:
        algorithm, iterations_raw, salt_b64, digest_b64 = stored_password_hash.split("$", 3)
    except ValueError:
        return False

    if algorithm != PASSWORD_HASH_ALGORITHM:
        return False

    try:
        iterations = int(iterations_raw)
        salt = base64.b64decode(salt_b64.encode("ascii"))
        expected_digest = base64.b64decode(digest_b64.encode("ascii"))
    except (ValueError, TypeError):
        return False

    computed_digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        iterations,
        dklen=len(expected_digest),
    )
    return hmac.compare_digest(computed_digest, expected_digest)


def create_access_token(subject: str) -> str:
    expires = timedelta(minutes=get_access_token_expire_minutes())
    return _create_token(subject=subject, token_type=TOKEN_TYPE_ACCESS, expires_delta=expires)


def create_refresh_token(subject: str) -> str:
    expires = timedelta(days=get_refresh_token_expire_days())
    return _create_token(subject=subject, token_type=TOKEN_TYPE_REFRESH, expires_delta=expires)


def decode_token(token: str, expected_token_type: str | None = None) -> dict[str, Any]:
    try:
        payload = jwt.decode(
            token,
            get_jwt_secret_key(),
            algorithms=[get_jwt_algorithm()],
        )
    except ExpiredSignatureError as exc:
        raise TokenValidationError("Token has expired.") from exc
    except InvalidTokenError as exc:
        raise TokenValidationError("Invalid token.") from exc

    subject = payload.get("sub")
    if not isinstance(subject, str) or not subject:
        raise TokenValidationError("Invalid token subject.")

    if expected_token_type:
        token_type = payload.get("type")
        if token_type != expected_token_type:
            raise TokenValidationError("Invalid token type.")

    return payload


def _create_token(subject: str, token_type: str, expires_delta: timedelta) -> str:
    issued_at = datetime.now(UTC)
    expires_at = issued_at + expires_delta
    payload = {
        "sub": subject,
        "type": token_type,
        "iat": int(issued_at.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    return jwt.encode(payload, get_jwt_secret_key(), algorithm=get_jwt_algorithm())
