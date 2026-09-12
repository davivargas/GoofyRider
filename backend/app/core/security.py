import base64
from collections.abc import Mapping
from collections.abc import Sequence
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from functools import lru_cache
import hashlib
import hmac
import secrets
import threading
from typing import Any
from typing import Protocol
from typing import cast
import uuid

from argon2 import PasswordHasher
from argon2 import exceptions as argon2_exceptions
from argon2.low_level import Type as Argon2Type
import jwt
from jwt import ExpiredSignatureError
from jwt import InvalidTokenError

from app.core.config import get_settings

TOKEN_TYPE_ACCESS = "access"
PASSWORD_HASH_ALGORITHM = "pbkdf2_sha256"
PASSWORD_HASH_ITERATIONS = 390000
SALT_BYTES = 16
KEY_BYTES = 32
ARGON2_PREFIX = "$argon2id$"
PBKDF2_PREFIX = f"{PASSWORD_HASH_ALGORITHM}$"

# Each Argon2id hash/verify allocates ~64 MiB (argon2_memory_kib). FastAPI's
# sync routes run on a threadpool, so a burst of concurrent auth requests
# could otherwise allocate memory_kib * threadpool-size all at once. Bound
# the number of hashes running at the same time to cap that burst.
ARGON2_MAX_CONCURRENT_HASHES = 4
_argon2_semaphore = threading.BoundedSemaphore(ARGON2_MAX_CONCURRENT_HASHES)


class TokenValidationError(Exception):
    pass


class JwtDecodeProtocol(Protocol):
    def __call__(
        self,
        jwt: str | bytes,
        key: object = "",
        algorithms: Sequence[str] | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]: ...


class JwtEncodeProtocol(Protocol):
    def __call__(
        self,
        payload: Mapping[str, Any],
        key: object,
        algorithm: str | None = None,
        **kwargs: Any,
    ) -> str: ...


jwt_decode = cast(JwtDecodeProtocol, jwt.decode)
jwt_encode = cast(JwtEncodeProtocol, jwt.encode)


def _password_hasher() -> PasswordHasher:
    settings = get_settings()
    return PasswordHasher(
        time_cost=settings.argon2_time_cost,
        memory_cost=settings.argon2_memory_kib,
        parallelism=settings.argon2_parallelism,
        hash_len=KEY_BYTES,
        salt_len=SALT_BYTES,
        type=Argon2Type.ID,
    )


def hash_password(password: str) -> str:
    with _argon2_semaphore:
        return _password_hasher().hash(password)


def hash_password_pbkdf2(password: str) -> str:
    """Legacy PBKDF2-SHA256 hash. Kept so tests and data fixes can produce
    the pre-Argon2 format; production code never calls it."""
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
    return f"{PASSWORD_HASH_ALGORITHM}${PASSWORD_HASH_ITERATIONS}${salt_b64}${digest_b64}"


def verify_password(password: str, stored_password_hash: str) -> bool:
    if stored_password_hash.startswith(ARGON2_PREFIX):
        try:
            with _argon2_semaphore:
                return _password_hasher().verify(stored_password_hash, password)
        except (
            argon2_exceptions.VerifyMismatchError,
            argon2_exceptions.VerificationError,
            argon2_exceptions.InvalidHashError,
        ):
            return False
    if stored_password_hash.startswith(PBKDF2_PREFIX):
        return _verify_pbkdf2(password, stored_password_hash)
    return False


def needs_rehash(stored_password_hash: str) -> bool:
    if not stored_password_hash.startswith(ARGON2_PREFIX):
        return True
    try:
        return _password_hasher().check_needs_rehash(stored_password_hash)
    except argon2_exceptions.InvalidHashError:
        return True


@lru_cache(maxsize=1)
def dummy_password_hash() -> str:
    """Argon2id hash of a random secret, used to keep login timing uniform
    when the email is unknown. Computed once per process."""
    return hash_password(secrets.token_urlsafe(32))


def _verify_pbkdf2(password: str, stored_password_hash: str) -> bool:
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
    expires = timedelta(minutes=get_settings().access_token_expire_minutes)
    return _create_token(subject=subject, token_type=TOKEN_TYPE_ACCESS, expires_delta=expires)


def generate_refresh_token() -> tuple[str, str]:
    """Return `(wire_token, token_hash)`. Only the hash is ever stored."""
    raw = secrets.token_bytes(32)
    wire = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
    return wire, hash_refresh_token(wire)


def hash_refresh_token(wire_token: str) -> str:
    return hashlib.sha256(wire_token.encode("utf-8")).hexdigest()


def decode_token(token: str, expected_token_type: str | None = None) -> dict[str, Any]:
    settings = get_settings()
    try:
        payload = jwt_decode(
            token,
            settings.require_jwt_secret_key(),
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
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
    settings = get_settings()
    payload: dict[str, str | int] = {
        "sub": subject,
        "type": token_type,
        "iat": int(issued_at.timestamp()),
        "exp": int(expires_at.timestamp()),
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "jti": uuid.uuid4().hex,
    }
    return jwt_encode(
        payload,
        settings.require_jwt_secret_key(),
        algorithm=settings.jwt_algorithm,
    )
