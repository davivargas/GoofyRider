from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import jwt
import pytest

from app.core.config import get_settings
from app.core.security import ARGON2_PREFIX
from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import decode_token
from app.core.security import dummy_password_hash
from app.core.security import generate_refresh_token
from app.core.security import hash_password
from app.core.security import hash_password_pbkdf2
from app.core.security import hash_refresh_token
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


def test_decode_token_rejects_expired_token() -> None:
    settings = get_settings()
    now = datetime.now(UTC)
    payload = {
        "sub": str(uuid4()),
        "type": TOKEN_TYPE_ACCESS,
        "iat": int((now - timedelta(minutes=10)).timestamp()),
        "exp": int((now - timedelta(minutes=5)).timestamp()),
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
    }
    token = jwt.encode(payload, settings.require_jwt_secret_key(), algorithm=settings.jwt_algorithm)

    with pytest.raises(TokenValidationError, match=r"Token has expired."):
        decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)


def test_decode_token_rejects_invalid_subject() -> None:
    settings = get_settings()
    now = datetime.now(UTC)
    payload = {
        "sub": "",
        "type": TOKEN_TYPE_ACCESS,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=5)).timestamp()),
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
    }
    token = jwt.encode(payload, settings.require_jwt_secret_key(), algorithm=settings.jwt_algorithm)

    with pytest.raises(TokenValidationError, match=r"Invalid token subject."):
        decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)


def test_access_token_carries_issuer_audience_and_jti() -> None:
    settings = get_settings()
    token = create_access_token(str(uuid4()))
    payload = decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)

    assert payload["iss"] == settings.jwt_issuer
    assert payload["aud"] == settings.jwt_audience
    assert len(payload["jti"]) == 32


def test_decode_token_rejects_wrong_issuer_and_audience() -> None:
    settings = get_settings()
    now = datetime.now(UTC)
    base = {
        "sub": str(uuid4()),
        "type": TOKEN_TYPE_ACCESS,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=5)).timestamp()),
        "jti": "x" * 32,
    }
    key = settings.require_jwt_secret_key()

    wrong_issuer = jwt.encode(
        {**base, "iss": "someone-else", "aud": settings.jwt_audience},
        key,
        algorithm=settings.jwt_algorithm,
    )
    wrong_audience = jwt.encode(
        {**base, "iss": settings.jwt_issuer, "aud": "other-app"},
        key,
        algorithm=settings.jwt_algorithm,
    )
    missing_claims = jwt.encode(base, key, algorithm=settings.jwt_algorithm)

    for token in (wrong_issuer, wrong_audience, missing_claims):
        with pytest.raises(TokenValidationError, match=r"Invalid token."):
            decode_token(token, expected_token_type=TOKEN_TYPE_ACCESS)


def test_generate_refresh_token_returns_urlsafe_secret_and_sha256_hash() -> None:
    wire, token_hash = generate_refresh_token()

    assert len(wire) == 43
    assert "=" not in wire and "+" not in wire and "/" not in wire
    assert len(token_hash) == 64
    assert token_hash == hash_refresh_token(wire)
    assert generate_refresh_token()[0] != wire
