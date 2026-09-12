from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import jwt
import pytest

from app.core.config import get_settings
from app.core.security import ARGON2_PREFIX
from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TOKEN_TYPE_REFRESH
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import create_refresh_token
from app.core.security import decode_token
from app.core.security import dummy_password_hash
from app.core.security import hash_password
from app.core.security import hash_password_pbkdf2
from app.core.security import needs_rehash
from app.core.security import verify_password


def test_hash_password_produces_argon2id() -> None:
    stored_hash = hash_password("super-secure-pass-123")

    assert stored_hash.startswith(ARGON2_PREFIX)
    assert verify_password("super-secure-pass-123", stored_hash) is True
    assert verify_password("wrong-password", stored_hash) is False


def test_verify_password_accepts_legacy_pbkdf2_hash() -> None:
    stored_hash = hash_password_pbkdf2("legacy-pass")

    assert stored_hash.startswith("pbkdf2_sha256$")
    assert verify_password("legacy-pass", stored_hash) is True
    assert verify_password("nope", stored_hash) is False


def test_verify_password_rejects_malformed_hash() -> None:
    assert verify_password("anything", "not-a-valid-hash-format") is False


def test_needs_rehash_for_pbkdf2_and_stale_argon2_params(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert needs_rehash(hash_password_pbkdf2("x")) is True
    assert needs_rehash("garbage") is True

    current = hash_password("x")
    assert needs_rehash(current) is False

    monkeypatch.setenv("ARGON2_TIME_COST", "2")
    get_settings.cache_clear()
    assert needs_rehash(current) is True


def test_dummy_password_hash_is_verifiable_argon2() -> None:
    dummy = dummy_password_hash()

    assert dummy.startswith(ARGON2_PREFIX)
    assert verify_password("definitely-not-the-secret", dummy) is False
    assert dummy_password_hash() == dummy


def test_create_and_decode_access_token() -> None:
    subject = str(uuid4())
    token = create_access_token(subject)
    payload = decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)

    assert payload["sub"] == subject
    assert payload["type"] == TOKEN_TYPE_ACCESS


def test_refresh_token_rejected_when_access_expected() -> None:
    token = create_refresh_token(str(uuid4()))

    with pytest.raises(TokenValidationError, match=r"Invalid token type."):
        decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)


def test_decode_token_rejects_expired_token() -> None:
    now = datetime.now(UTC)
    payload = {
        "sub": str(uuid4()),
        "type": TOKEN_TYPE_ACCESS,
        "iat": int((now - timedelta(minutes=10)).timestamp()),
        "exp": int((now - timedelta(minutes=5)).timestamp()),
    }
    settings = get_settings()
    token = jwt.encode(payload, settings.require_jwt_secret_key(), algorithm=settings.jwt_algorithm)

    with pytest.raises(TokenValidationError, match=r"Token has expired."):
        decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)


def test_decode_token_rejects_invalid_subject() -> None:
    now = datetime.now(UTC)
    payload = {
        "sub": "",
        "type": TOKEN_TYPE_REFRESH,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=5)).timestamp()),
    }
    settings = get_settings()
    token = jwt.encode(payload, settings.require_jwt_secret_key(), algorithm=settings.jwt_algorithm)

    with pytest.raises(TokenValidationError, match=r"Invalid token subject."):
        decode_token(token, expected_token_type=TOKEN_TYPE_REFRESH)
