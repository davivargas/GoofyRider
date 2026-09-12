# Security Hardening (Backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace stateless JWT refresh tokens with server-stored, rotating, revocable refresh tokens; move password hashing to Argon2id; rate-limit the auth endpoints; cap point storage; gate the API docs; and remove personal data from logs.

**Architecture:** Everything stays inside the existing `api -> services -> repositories -> models` layering. A new `refresh_tokens` table and repository hold token state; `AuthService` owns rotation and reuse detection; a small in-process `RateLimiter` sits behind a protocol and is applied through FastAPI dependencies; all knobs are `AppSettings` fields.

**Tech Stack:** FastAPI, SQLAlchemy 2.0 typed models, Alembic, Pydantic v2, PyJWT, `argon2-cffi` (new), pytest against the dedicated Postgres test database.

**Spec:** `docs/superpowers/specs/2026-09-12-security-hardening-design.md` (sections 2, 3, 6, 7, 8). Mobile follow-up: `docs/superpowers/plans/2026-09-12-security-hardening-mobile.md`.

## Global Constraints

- Follow `CLAUDE.md`: routers thin; services raise `ServiceError` subclasses only; repositories are the only SQLAlchemy consumers; new repository methods go in `app/repositories/protocols.py` first; settings are read via `get_settings().<name>`; `PositiveInt` for counts and intervals; every schema change gets exactly one Alembic revision (next is `0013`; `0005` stays absent).
- Quality gates before the branch is done: `ruff check .`, `ruff format --check .`, `mypy`, `python -m pytest` (run from `goofyrider/backend/`). Pre-existing failures listed in audit H1 (ruff, mypy in the Slopes importer, analyzer typing) are out of scope here; do not let this plan add new ones in touched files.
- Backend tests run against the dedicated test database only. Local setup used by the audit: `docker compose up -d db`, create `goofyrider_test`, export `DATABASE_URL=postgresql+psycopg://<user>:<password>@localhost:5432/goofyrider_test` and `JWT_SECRET_KEY=test-jwt-secret-key-at-least-32-chars`, then `alembic upgrade head`.
- Wire messages are exact strings; tests assert on them: `Invalid email or password.`, `Invalid or expired refresh token.`, `Invalid token.`, `Session point limit exceeded.`, `Too many requests. Try again in {n} seconds.`
- Commit after every task on `fable-review`. Commit messages end with the session attribution line configured for this repository.

---

### Task 1: Settings for the new knobs

**Files:**
- Modify: `app/core/config.py`
- Modify: `tests/conftest.py`
- Modify: `tests/unit/test_config.py`
- Modify: `docker-compose.yml`
- Modify: `.env.example`

**Interfaces:**
- Produces on `AppSettings`: `debug: bool`, `jwt_issuer: str`, `jwt_audience: str`, `access_token_expire_minutes` (default now 15), `refresh_token_expire_days` (default now 30), `refresh_token_family_max_days: PositiveInt`, `argon2_memory_kib`, `argon2_time_cost`, `argon2_parallelism`, `rate_limit_enabled: bool`, `rate_limit_window_seconds`, `rate_limit_register_window_seconds`, `rate_limit_login_per_ip`, `rate_limit_login_per_email`, `rate_limit_register_per_ip`, `rate_limit_refresh_per_ip`, `trust_proxy_headers: bool`, `max_points_per_session`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_config.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_config.py -q`
Expected: the four new tests fail with `AttributeError` or wrong defaults.

- [ ] **Step 3: Add the settings**

In `app/core/config.py`, import `model_validator` from `pydantic`, and inside `AppSettings` replace the two existing token lifetime lines and add the new fields:

```python
    jwt_secret_key: str | None = None
    jwt_algorithm: str = "HS256"
    jwt_issuer: str = "fall-line-api"
    jwt_audience: str = "fall-line-mobile"

    access_token_expire_minutes: PositiveInt = 15
    refresh_token_expire_days: PositiveInt = 30
    refresh_token_family_max_days: PositiveInt = 90

    debug: bool = False

    argon2_memory_kib: PositiveInt = 65536
    argon2_time_cost: PositiveInt = 3
    argon2_parallelism: PositiveInt = 4

    rate_limit_enabled: bool = True
    rate_limit_window_seconds: PositiveInt = 300
    rate_limit_register_window_seconds: PositiveInt = 3600
    rate_limit_login_per_ip: PositiveInt = 10
    rate_limit_login_per_email: PositiveInt = 5
    rate_limit_register_per_ip: PositiveInt = 5
    rate_limit_refresh_per_ip: PositiveInt = 30
    trust_proxy_headers: bool = False

    max_points_per_session: PositiveInt = 200000
```

and add the validator after the existing field validators:

```python
    @model_validator(mode="after")
    def _validate_refresh_lifetimes(self) -> "AppSettings":
        if self.refresh_token_family_max_days < self.refresh_token_expire_days:
            raise ValueError(
                "REFRESH_TOKEN_FAMILY_MAX_DAYS must be >= REFRESH_TOKEN_EXPIRE_DAYS."
            )
        return self
```

`_raise_settings_validation_error` already strips the `Value error, ` prefix for `value_error` entries, so the message surfaces unchanged.

- [ ] **Step 4: Keep the test suite fast**

Append to `tests/conftest.py`:

```python
@pytest.fixture(autouse=True)
def _fast_argon2(monkeypatch: pytest.MonkeyPatch) -> None:
    """Argon2id at production cost takes ~150 ms per hash; tests use a small profile."""
    monkeypatch.setenv("ARGON2_MEMORY_KIB", "8192")
    monkeypatch.setenv("ARGON2_TIME_COST", "1")
    monkeypatch.setenv("ARGON2_PARALLELISM", "1")
```

- [ ] **Step 5: Wire the environment**

In `docker-compose.yml` under the backend `environment:` block replace the two token lines and add:

```yaml
      ACCESS_TOKEN_EXPIRE_MINUTES: ${ACCESS_TOKEN_EXPIRE_MINUTES:-15}
      REFRESH_TOKEN_EXPIRE_DAYS: ${REFRESH_TOKEN_EXPIRE_DAYS:-30}
      REFRESH_TOKEN_FAMILY_MAX_DAYS: ${REFRESH_TOKEN_FAMILY_MAX_DAYS:-90}
      JWT_ISSUER: ${JWT_ISSUER:-fall-line-api}
      JWT_AUDIENCE: ${JWT_AUDIENCE:-fall-line-mobile}
      DEBUG: ${DEBUG:-false}
      ARGON2_MEMORY_KIB: ${ARGON2_MEMORY_KIB:-65536}
      ARGON2_TIME_COST: ${ARGON2_TIME_COST:-3}
      ARGON2_PARALLELISM: ${ARGON2_PARALLELISM:-4}
      RATE_LIMIT_ENABLED: ${RATE_LIMIT_ENABLED:-true}
      RATE_LIMIT_WINDOW_SECONDS: ${RATE_LIMIT_WINDOW_SECONDS:-300}
      RATE_LIMIT_REGISTER_WINDOW_SECONDS: ${RATE_LIMIT_REGISTER_WINDOW_SECONDS:-3600}
      RATE_LIMIT_LOGIN_PER_IP: ${RATE_LIMIT_LOGIN_PER_IP:-10}
      RATE_LIMIT_LOGIN_PER_EMAIL: ${RATE_LIMIT_LOGIN_PER_EMAIL:-5}
      RATE_LIMIT_REGISTER_PER_IP: ${RATE_LIMIT_REGISTER_PER_IP:-5}
      RATE_LIMIT_REFRESH_PER_IP: ${RATE_LIMIT_REFRESH_PER_IP:-30}
      TRUST_PROXY_HEADERS: ${TRUST_PROXY_HEADERS:-false}
      MAX_POINTS_PER_SESSION: ${MAX_POINTS_PER_SESSION:-200000}
```

and change the `db` service port mapping to `- "127.0.0.1:5432:5432"`.

In `.env.example` replace `ACCESS_TOKEN_EXPIRE_MINUTES=30` and `REFRESH_TOKEN_EXPIRE_DAYS=14` with:

```
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=30
REFRESH_TOKEN_FAMILY_MAX_DAYS=90
JWT_ISSUER=fall-line-api
JWT_AUDIENCE=fall-line-mobile

# Set to true only on a development machine: exposes /docs, /redoc and /openapi.json.
DEBUG=false

# Argon2id password hashing (OWASP 2026 baseline). Lower only for constrained hosts.
ARGON2_MEMORY_KIB=65536
ARGON2_TIME_COST=3
ARGON2_PARALLELISM=4

# Auth rate limits (per window).
RATE_LIMIT_ENABLED=true
RATE_LIMIT_WINDOW_SECONDS=300
RATE_LIMIT_REGISTER_WINDOW_SECONDS=3600
RATE_LIMIT_LOGIN_PER_IP=10
RATE_LIMIT_LOGIN_PER_EMAIL=5
RATE_LIMIT_REGISTER_PER_IP=5
RATE_LIMIT_REFRESH_PER_IP=30
# Honour X-Forwarded-For only behind a trusted reverse proxy.
TRUST_PROXY_HEADERS=false

# Storage cap per session (about 55 hours at 1 Hz).
MAX_POINTS_PER_SESSION=200000
```

- [ ] **Step 6: Run the config tests**

Run: `python -m pytest tests/unit/test_config.py -q`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add app/core/config.py tests/conftest.py tests/unit/test_config.py docker-compose.yml .env.example
git commit -m "feat(backend): add security hardening settings"
```

---

### Task 2: Argon2id password hashing with PBKDF2 compatibility

**Files:**
- Modify: `pyproject.toml` (add `argon2-cffi>=23.1` to `dependencies`)
- Modify: `app/core/security.py`
- Modify: `tests/unit/test_security.py`

**Interfaces:**
- Produces in `app.core.security`: `hash_password(password) -> str` (Argon2id), `hash_password_pbkdf2(password) -> str` (legacy, kept for tests and migrations), `verify_password(password, stored_hash) -> bool` (both formats), `needs_rehash(stored_hash) -> bool`, `dummy_password_hash() -> str` (cached), constant `ARGON2_PREFIX = "$argon2id$"`.

- [ ] **Step 1: Install the dependency**

Add `"argon2-cffi>=23.1",` to `dependencies` in `pyproject.toml`, then run `pip install -e .[dev]`.

- [ ] **Step 2: Write the failing tests**

Replace the first three tests in `tests/unit/test_security.py` with:

```python
from app.core.security import ARGON2_PREFIX
from app.core.security import dummy_password_hash
from app.core.security import hash_password_pbkdf2
from app.core.security import needs_rehash


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
```

(Keep the existing imports; add the four new ones above.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_security.py -q`
Expected: ImportError for the new names.

- [ ] **Step 4: Implement**

In `app/core/security.py` add imports and replace `hash_password` / `verify_password`:

```python
from functools import lru_cache

from argon2 import PasswordHasher
from argon2 import exceptions as argon2_exceptions
from argon2.low_level import Type as Argon2Type

ARGON2_PREFIX = "$argon2id$"
PBKDF2_PREFIX = f"{PASSWORD_HASH_ALGORITHM}$"


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
```

- [ ] **Step 5: Run the tests**

Run: `python -m pytest tests/unit/test_security.py tests/unit/test_auth_service.py -q`
Expected: all pass (the auth service tests still use `hash_password`, which now returns Argon2 and still verifies).

- [ ] **Step 6: Commit**

```bash
git add pyproject.toml app/core/security.py tests/unit/test_security.py
git commit -m "feat(backend): hash passwords with Argon2id, keep PBKDF2 verification"
```

---

### Task 3: Access-token claims and opaque refresh-token helpers

**Files:**
- Modify: `app/core/security.py`
- Modify: `tests/unit/test_security.py`

**Interfaces:**
- Produces: `create_access_token(subject) -> str` now carries `iss`, `aud`, `jti`; `decode_token` verifies issuer and audience; `generate_refresh_token() -> tuple[str, str]` returns `(wire_token, token_hash)`; `hash_refresh_token(wire_token) -> str` (64-char hex SHA-256). `create_refresh_token` and `TOKEN_TYPE_REFRESH` remain for now and are deleted in Task 6.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_security.py`:

```python
from app.core.security import generate_refresh_token
from app.core.security import hash_refresh_token


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
```

Also update the existing `test_decode_token_rejects_expired_token` and `test_decode_token_rejects_invalid_subject` payloads to include `"iss": settings.jwt_issuer` and `"aud": settings.jwt_audience` (move the `settings = get_settings()` line above the payload), otherwise they now fail on the issuer check before reaching the assertion they test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_security.py -q`
Expected: ImportError for `generate_refresh_token`.

- [ ] **Step 3: Implement**

In `app/core/security.py`:

```python
import uuid


def generate_refresh_token() -> tuple[str, str]:
    """Return `(wire_token, token_hash)`. Only the hash is ever stored."""
    raw = secrets.token_bytes(32)
    wire = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
    return wire, hash_refresh_token(wire)


def hash_refresh_token(wire_token: str) -> str:
    return hashlib.sha256(wire_token.encode("ascii")).hexdigest()
```

Replace `decode_token`'s `jwt_decode(...)` call with:

```python
        payload = jwt_decode(
            token,
            settings.require_jwt_secret_key(),
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
        )
```

(`InvalidIssuerError`, `InvalidAudienceError`, and `MissingRequiredClaimError` are all `InvalidTokenError` subclasses, so the existing `except InvalidTokenError` produces `Invalid token.`.)

Replace `_create_token`'s payload with:

```python
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
```

- [ ] **Step 4: Run the security, auth, dependency, and QA auth tests**

Run: `python -m pytest tests/unit/test_security.py tests/unit/test_auth_service.py tests/unit/test_dependencies.py tests/qa/test_auth_qa.py -q`
Expected: all pass (`create_refresh_token` still exists and now also carries the claims).

- [ ] **Step 5: Commit**

```bash
git add app/core/security.py tests/unit/test_security.py
git commit -m "feat(backend): add iss/aud/jti to access tokens and opaque refresh token helpers"
```

---

### Task 4: RefreshToken model and migration 0013

**Files:**
- Create: `app/models/refresh_token.py`
- Modify: `app/models/__init__.py`
- Create: `alembic/versions/0013_refresh_tokens.py`

**Interfaces:**
- Produces: `RefreshToken` SQLAlchemy model with columns `id`, `user_id`, `token_hash`, `family_id`, `device_label`, `issued_at`, `expires_at`, `family_expires_at`, `last_used_at`, `revoked_at`, `replaced_by_id`.

- [ ] **Step 1: Write the model**

```python
# app/models/refresh_token.py
from __future__ import annotations

from datetime import datetime
import uuid

from sqlalchemy import DateTime
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import String
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    __table_args__ = (Index("ix_refresh_tokens_family_id", "family_id"),)

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    family_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    device_label: Mapped[str | None] = mapped_column(String(80), nullable=True)
    issued_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    family_expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    last_used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    replaced_by_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("refresh_tokens.id", ondelete="SET NULL"),
        nullable=True,
    )
```

Add `from app.models.refresh_token import RefreshToken` to `app/models/__init__.py` in alphabetical position (after `favorite_resort`, before `resort`, because `refresh_token` sorts before `resort`) and `"RefreshToken"` to `__all__` in the same position (after `"FavoriteResort"`).

- [ ] **Step 2: Write the migration**

```python
# alembic/versions/0013_refresh_tokens.py
"""refresh tokens

Revision ID: 0013_refresh_tokens
Revises: 0012_session_analytics_defaults
Create Date: 2026-09-12 12:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0013_refresh_tokens"
down_revision: Union[str, None] = "0012_session_analytics_defaults"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "refresh_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, nullable=False),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("family_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("device_label", sa.String(length=80), nullable=True),
        sa.Column(
            "issued_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("family_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "replaced_by_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("refresh_tokens.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.UniqueConstraint("token_hash", name="uq_refresh_tokens_token_hash"),
    )
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"])
    op.create_index("ix_refresh_tokens_family_id", "refresh_tokens", ["family_id"])


def downgrade() -> None:
    op.drop_index("ix_refresh_tokens_family_id", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_user_id", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")
```

- [ ] **Step 3: Verify the migration round-trips**

Run (with `DATABASE_URL` pointing at the test database): `alembic upgrade head && alembic downgrade -1 && alembic upgrade head`
Expected: three successful runs, ending at `0013_refresh_tokens`.

- [ ] **Step 4: Run the existing suite for regressions**

Run: `python -m pytest tests/unit/test_schema_validation.py tests/qa/test_system_qa.py -q`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/refresh_token.py app/models/__init__.py alembic/versions/0013_refresh_tokens.py
git commit -m "feat(backend): add refresh_tokens table"
```

---

### Task 5: RefreshTokenRepository

**Files:**
- Modify: `app/repositories/protocols.py`
- Create: `app/repositories/refresh_token_repository.py`
- Modify: `app/repositories/__init__.py`
- Modify: `tests/unit/repositories/conftest.py` (add `refresh_tokens` to `TABLES_TO_TRUNCATE`, first entry)
- Modify: `tests/qa/conftest.py` (add `refresh_tokens` to `TABLES_TO_TRUNCATE`, first entry)
- Test: `tests/unit/repositories/test_refresh_token_repository.py` (new)

**Interfaces:**
- Produces `RefreshTokenRepositoryProtocol` and `RefreshTokenRepository` with `add(token)`, `get_by_hash(token_hash) -> RefreshToken | None`, `revoke(token, *, now, replaced_by=None)`, `revoke_family(family_id, *, now) -> int`, `delete_expired(*, now) -> int`, `commit()`, `rollback()`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/repositories/test_refresh_token_repository.py
from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

from sqlalchemy.orm import Session

from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.repositories.refresh_token_repository import RefreshTokenRepository


def _token(user: User, *, family_id=None, hash_suffix: str = "a") -> RefreshToken:
    now = datetime.now(UTC)
    return RefreshToken(
        user_id=user.id,
        token_hash=(hash_suffix * 64)[:64],
        family_id=family_id or uuid4(),
        issued_at=now,
        expires_at=now + timedelta(days=30),
        family_expires_at=now + timedelta(days=90),
    )


def test_add_and_get_by_hash(db: Session, create_user: Callable[..., User]) -> None:
    repo = RefreshTokenRepository(db)
    token = _token(create_user())

    repo.add(token)
    repo.commit()

    assert repo.get_by_hash(token.token_hash) is not None
    assert repo.get_by_hash("b" * 64) is None


def test_revoke_links_successor(db: Session, create_user: Callable[..., User]) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    old = _token(user, hash_suffix="1")
    repo.add(old)
    repo.commit()
    successor = _token(user, family_id=old.family_id, hash_suffix="2")
    now = datetime.now(UTC)

    repo.revoke(old, now=now, replaced_by=successor)
    repo.commit()

    stored_old = repo.get_by_hash(old.token_hash)
    stored_new = repo.get_by_hash(successor.token_hash)
    assert stored_old is not None and stored_new is not None
    assert stored_old.revoked_at is not None
    assert stored_old.replaced_by_id == stored_new.id
    assert stored_new.revoked_at is None


def test_revoke_family_only_touches_active_members(
    db: Session, create_user: Callable[..., User]
) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    family = uuid4()
    first = _token(user, family_id=family, hash_suffix="3")
    second = _token(user, family_id=family, hash_suffix="4")
    other = _token(user, hash_suffix="5")
    for token in (first, second, other):
        repo.add(token)
    repo.commit()
    repo.revoke(first, now=datetime.now(UTC))
    repo.commit()

    count = repo.revoke_family(family, now=datetime.now(UTC))
    repo.commit()

    assert count == 1
    assert repo.get_by_hash(second.token_hash).revoked_at is not None
    assert repo.get_by_hash(other.token_hash).revoked_at is None


def test_delete_expired_removes_dead_families_and_old_rotations(
    db: Session, create_user: Callable[..., User]
) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    now = datetime.now(UTC)
    dead_family = _token(user, hash_suffix="6")
    dead_family.family_expires_at = now - timedelta(days=1)
    old_rotation = _token(user, hash_suffix="7")
    old_rotation.expires_at = now - timedelta(days=8)
    alive = _token(user, hash_suffix="8")
    for token in (dead_family, old_rotation, alive):
        repo.add(token)
    repo.commit()

    removed = repo.delete_expired(now=now)
    repo.commit()

    assert removed == 2
    assert repo.get_by_hash(alive.token_hash) is not None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/unit/repositories/test_refresh_token_repository.py -q`
Expected: ImportError.

- [ ] **Step 3: Add the protocol**

Append to `app/repositories/protocols.py` (import `from datetime import datetime` and `from app.models.refresh_token import RefreshToken` at the top, and add `"RefreshTokenRepositoryProtocol"` to `__all__`):

```python
class RefreshTokenRepositoryProtocol(Protocol):
    def add(self, token: RefreshToken) -> None: ...

    def get_by_hash(self, token_hash: str) -> RefreshToken | None: ...

    def revoke(
        self,
        token: RefreshToken,
        *,
        now: datetime,
        replaced_by: RefreshToken | None = None,
    ) -> None: ...

    def revoke_family(self, family_id: uuid.UUID, *, now: datetime) -> int: ...

    def delete_expired(self, *, now: datetime) -> int: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...
```

- [ ] **Step 4: Implement the repository**

```python
# app/repositories/refresh_token_repository.py
from datetime import datetime
from datetime import timedelta
import uuid

from sqlalchemy import delete
from sqlalchemy import or_
from sqlalchemy import select
from sqlalchemy import update

from app.models.refresh_token import RefreshToken
from app.repositories.base import SqlAlchemyRepository

ROTATED_TOKEN_RETENTION = timedelta(days=7)


class RefreshTokenRepository(SqlAlchemyRepository):
    def add(self, token: RefreshToken) -> None:
        self._db.add(token)

    def get_by_hash(self, token_hash: str) -> RefreshToken | None:
        return self._db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))

    def revoke(
        self,
        token: RefreshToken,
        *,
        now: datetime,
        replaced_by: RefreshToken | None = None,
    ) -> None:
        token.revoked_at = now
        if replaced_by is not None:
            self._db.add(replaced_by)
            self._db.flush()
            token.replaced_by_id = replaced_by.id

    def revoke_family(self, family_id: uuid.UUID, *, now: datetime) -> int:
        result = self._db.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=now)
        )
        return int(getattr(result, "rowcount", 0) or 0)

    def delete_expired(self, *, now: datetime) -> int:
        result = self._db.execute(
            delete(RefreshToken).where(
                or_(
                    RefreshToken.family_expires_at < now,
                    RefreshToken.expires_at < now - ROTATED_TOKEN_RETENTION,
                )
            )
        )
        return int(getattr(result, "rowcount", 0) or 0)
```

Add `from app.repositories.refresh_token_repository import RefreshTokenRepository` and `"RefreshTokenRepository"` to `app/repositories/__init__.py` in alphabetical order. Add `"refresh_tokens",` as the first entry of `TABLES_TO_TRUNCATE` in both conftest files.

- [ ] **Step 5: Run the tests**

Run: `python -m pytest tests/unit/repositories/test_refresh_token_repository.py -q`
Expected: 4 pass.

- [ ] **Step 6: Commit**

```bash
git add app/repositories tests/unit/repositories/conftest.py tests/unit/repositories/test_refresh_token_repository.py tests/qa/conftest.py
git commit -m "feat(backend): refresh token repository"
```

---

### Task 6: AuthService rotation, reuse detection, logout, re-hash

**Files:**
- Modify: `app/services/auth_service.py`
- Modify: `app/core/security.py` (delete `create_refresh_token`, `TOKEN_TYPE_REFRESH`)
- Modify: `app/schemas/auth.py`
- Modify: `app/core/dependencies/auth.py`, `app/core/dependencies/__init__.py`
- Modify: `app/api/auth.py`
- Modify: `tests/unit/test_auth_service.py`, `tests/unit/test_security.py`, `tests/qa/test_auth_qa.py`

**Interfaces:**
- Consumes: `RefreshTokenRepositoryProtocol` (Task 5), `generate_refresh_token`, `hash_refresh_token`, `needs_rehash`, `dummy_password_hash` (Tasks 2 and 3), settings (Task 1).
- Produces: `AuthService(user_repository, refresh_token_repository, clock=None)` with `register(email, password, display_name, device_label=None)`, `login(email, password, device_label=None)`, `refresh(refresh_token, device_label=None)`, `logout(refresh_token)`, `get_user_from_access_token(access_token)`. Schemas `RegisterRequest`, `LoginRequest`, `RefreshTokenRequest` gain `device_label: DeviceLabel | None = None`. Dependency `get_refresh_token_repository`.

- [ ] **Step 1: Rewrite the unit tests**

Replace `tests/unit/test_auth_service.py` with:

```python
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy.exc import IntegrityError

from app.core.security import ARGON2_PREFIX
from app.core.security import hash_password
from app.core.security import hash_password_pbkdf2
from app.models.refresh_token import RefreshToken
from app.models.user import User
import app.services.auth_service as auth_service_module
from app.services.auth_service import AuthService
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError


class FakeUserRepository:
    def __init__(self) -> None:
        self.users_by_email: dict[str, User] = {}
        self.users_by_id: dict[object, User] = {}
        self.pending_user: User | None = None
        self.commit_error: Exception | None = None
        self.did_rollback = False
        self.commit_count = 0

    def get_by_email(self, email: str) -> User | None:
        return self.users_by_email.get(email)

    def get_by_id(self, user_id) -> User | None:
        return self.users_by_id.get(user_id)

    def add(self, user: User) -> None:
        self.pending_user = user

    def commit(self) -> None:
        self.commit_count += 1
        if self.commit_error is not None:
            raise self.commit_error
        if self.pending_user is None:
            return
        if self.pending_user.id is None:
            self.pending_user.id = uuid4()
        self.users_by_email[self.pending_user.email] = self.pending_user
        self.users_by_id[self.pending_user.id] = self.pending_user
        self.pending_user = None

    def rollback(self) -> None:
        self.did_rollback = True

    def refresh(self, _instance: object) -> None:
        return None


class FakeRefreshTokenRepository:
    def __init__(self) -> None:
        self.tokens: list[RefreshToken] = []
        self.commit_count = 0

    def add(self, token: RefreshToken) -> None:
        if token.id is None:
            token.id = uuid4()
        self.tokens.append(token)

    def get_by_hash(self, token_hash: str) -> RefreshToken | None:
        return next((t for t in self.tokens if t.token_hash == token_hash), None)

    def revoke(self, token: RefreshToken, *, now, replaced_by=None) -> None:
        token.revoked_at = now
        if replaced_by is not None:
            self.add(replaced_by)
            token.replaced_by_id = replaced_by.id

    def revoke_family(self, family_id, *, now) -> int:
        count = 0
        for token in self.tokens:
            if token.family_id == family_id and token.revoked_at is None:
                token.revoked_at = now
                count += 1
        return count

    def delete_expired(self, *, now) -> int:
        return 0

    def commit(self) -> None:
        self.commit_count += 1

    def rollback(self) -> None:
        return None


def _user(email: str = "rider@example.com", password: str = "strong-pass") -> User:
    user = User(email=email, password_hash=hash_password(password), display_name="Rider")
    user.id = uuid4()
    return user


def _service(
    users: FakeUserRepository | None = None,
    tokens: FakeRefreshTokenRepository | None = None,
    now: datetime | None = None,
) -> tuple[AuthService, FakeUserRepository, FakeRefreshTokenRepository]:
    users = users or FakeUserRepository()
    tokens = tokens or FakeRefreshTokenRepository()
    fixed_now = now or datetime(2026, 9, 12, 12, 0, tzinfo=UTC)
    service = AuthService(
        user_repository=users,
        refresh_token_repository=tokens,
        clock=lambda: fixed_now,
    )
    return service, users, tokens


def _seed_user(users: FakeUserRepository, user: User) -> None:
    users.users_by_email[user.email] = user
    users.users_by_id[user.id] = user


def test_register_rejects_duplicate_email() -> None:
    service, users, _ = _service()
    _seed_user(users, _user())

    with pytest.raises(ConflictError, match=r"Email is already registered."):
        service.register(email="rider@example.com", password="strong-pass", display_name="Rider")


def test_register_rolls_back_when_commit_fails() -> None:
    service, users, _ = _service()
    users.commit_error = IntegrityError("INSERT", {}, Exception("unique violation"))

    with pytest.raises(ConflictError, match=r"Email is already registered."):
        service.register(email="new@example.com", password="strong-pass", display_name="Rider")

    assert users.did_rollback is True


def test_register_issues_stored_refresh_token_with_device_label() -> None:
    service, _, tokens = _service()

    pair = service.register(
        email="new@example.com",
        password="strong-pass",
        display_name="Rider",
        device_label="Pixel 8 / Android 15",
    )

    assert pair["token_type"] == "bearer"
    assert len(tokens.tokens) == 1
    stored = tokens.tokens[0]
    assert stored.device_label == "Pixel 8 / Android 15"
    assert stored.token_hash != pair["refresh_token"]
    assert stored.family_expires_at - stored.issued_at == timedelta(days=90)


def test_login_rejects_unknown_email_with_uniform_timing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service, _, _ = _service()
    calls: list[str] = []
    monkeypatch.setattr(
        auth_service_module,
        "verify_password",
        lambda password, stored: calls.append(stored) or False,
    )

    with pytest.raises(AuthenticationError, match=r"Invalid email or password."):
        service.login(email="missing@example.com", password="bad-pass")

    assert len(calls) == 1
    assert calls[0].startswith(ARGON2_PREFIX)


def test_login_rejects_wrong_password() -> None:
    service, users, _ = _service()
    _seed_user(users, _user())

    with pytest.raises(AuthenticationError, match=r"Invalid email or password."):
        service.login(email="rider@example.com", password="wrong")


def test_login_rehashes_legacy_pbkdf2_password() -> None:
    service, users, tokens = _service()
    legacy = User(
        email="old@example.com",
        password_hash=hash_password_pbkdf2("legacy-pass"),
        display_name="Old",
    )
    legacy.id = uuid4()
    _seed_user(users, legacy)

    service.login(email="old@example.com", password="legacy-pass")

    assert legacy.password_hash.startswith(ARGON2_PREFIX)
    assert users.commit_count >= 1
    assert len(tokens.tokens) == 1


def test_refresh_rotates_and_revokes_previous_token() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    first = service.login(email="rider@example.com", password="strong-pass")

    second = service.refresh(first["refresh_token"])

    assert second["refresh_token"] != first["refresh_token"]
    old, new = tokens.tokens
    assert old.revoked_at is not None
    assert old.replaced_by_id == new.id
    assert new.family_id == old.family_id
    assert new.family_expires_at == old.family_expires_at


def test_refresh_reuse_revokes_whole_family() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    first = service.login(email="rider@example.com", password="strong-pass")
    second = service.refresh(first["refresh_token"])

    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(first["refresh_token"])

    assert all(t.revoked_at is not None for t in tokens.tokens)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(second["refresh_token"])


def test_refresh_rejects_unknown_expired_and_family_expired_tokens() -> None:
    now = datetime(2026, 9, 12, 12, 0, tzinfo=UTC)
    service, users, tokens = _service(now=now)
    _seed_user(users, _user())
    pair = service.login(email="rider@example.com", password="strong-pass")
    stored = tokens.tokens[0]

    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh("not-a-token")

    stored.expires_at = now - timedelta(seconds=1)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])

    stored.expires_at = now + timedelta(days=1)
    stored.family_expires_at = now - timedelta(seconds=1)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])


def test_logout_revokes_token_and_is_idempotent() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    pair = service.login(email="rider@example.com", password="strong-pass")

    service.logout(pair["refresh_token"])
    service.logout(pair["refresh_token"])
    service.logout("unknown")

    assert tokens.tokens[0].revoked_at is not None
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])


def test_get_user_from_access_token_rejects_unknown_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service, _, _ = _service()
    monkeypatch.setattr(
        auth_service_module,
        "decode_token",
        lambda _token, expected_token_type=None: {"sub": str(uuid4())},
    )

    with pytest.raises(AuthenticationError, match=r"User not found."):
        service.get_user_from_access_token("access-token")
```

- [ ] **Step 2: Rewrite the QA auth tests**

Replace `tests/qa/test_auth_qa.py` with:

```python
from fastapi.testclient import TestClient

from app.core.security import create_access_token

INVALID_REFRESH = "Invalid or expired refresh token."


def test_auth_register_login_refresh_me_logout_flow(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()

    login_response = client.post(
        "/v1/auth/login",
        json={
            "email": user["email"],
            "password": user["password"],
            "device_label": "QA Phone / Android 15",
        },
    )
    assert login_response.status_code == 200
    login_data = login_response.json()
    assert login_data["token_type"] == "bearer"

    me_response = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {login_data['access_token']}"},
    )
    assert me_response.status_code == 200
    assert me_response.json()["email"] == user["email"]

    refresh_response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": login_data["refresh_token"]},
    )
    assert refresh_response.status_code == 200
    refreshed = refresh_response.json()
    assert refreshed["refresh_token"] != login_data["refresh_token"]

    stale = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": login_data["refresh_token"]},
    )
    assert stale.status_code == 401
    assert stale.json()["detail"] == INVALID_REFRESH

    # Reuse of the rotated token revoked the family, so the newest token is dead too.
    after_reuse = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": refreshed["refresh_token"]},
    )
    assert after_reuse.status_code == 401


def test_auth_logout_revokes_refresh_token(client: TestClient, register_user) -> None:
    user = register_user()

    logout_response = client.post(
        "/v1/auth/logout",
        json={"refresh_token": user["refresh_token"]},
    )
    assert logout_response.status_code == 204

    refresh_response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": user["refresh_token"]},
    )
    assert refresh_response.status_code == 401
    assert refresh_response.json()["detail"] == INVALID_REFRESH

    again = client.post("/v1/auth/logout", json={"refresh_token": user["refresh_token"]})
    assert again.status_code == 204


def test_auth_register_duplicate_email_conflict(client: TestClient, register_user) -> None:
    first_user = register_user()

    duplicate_response = client.post(
        "/v1/auth/register",
        json={
            "email": first_user["email"],
            "password": "another-strong-pass",
            "display_name": "Duplicate User",
        },
    )
    assert duplicate_response.status_code == 409
    assert duplicate_response.json()["detail"] == "Email is already registered."


def test_auth_login_invalid_password_returns_401(client: TestClient, register_user) -> None:
    user = register_user()

    response = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": "wrong-password"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid email or password."


def test_auth_me_without_token_returns_401(client: TestClient) -> None:
    response = client.get("/v1/auth/me")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_auth_refresh_rejects_access_token_and_garbage(client: TestClient, register_user) -> None:
    user = register_user()

    for bad in (user["access_token"], "not-a-token"):
        response = client.post("/v1/auth/refresh", json={"refresh_token": bad})
        assert response.status_code == 401
        assert response.json()["detail"] == INVALID_REFRESH


def test_auth_me_rejects_access_token_with_invalid_subject(client: TestClient) -> None:
    invalid_access = create_access_token("not-a-uuid")
    response = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {invalid_access}"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token subject."


def test_auth_device_label_is_optional_and_bounded(client: TestClient, register_user) -> None:
    user = register_user()

    too_long = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"], "device_label": "x" * 81},
    )
    assert too_long.status_code == 422

    ok = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"]},
    )
    assert ok.status_code == 200
```

In `tests/unit/test_security.py` delete `test_refresh_token_rejected_when_access_expected` and the `create_refresh_token` / `TOKEN_TYPE_REFRESH` imports; change `test_decode_token_rejects_invalid_subject` to use `TOKEN_TYPE_ACCESS`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_auth_service.py -q`
Expected: failures on the new `AuthService` constructor signature.

- [ ] **Step 4: Update the schemas**

In `app/schemas/auth.py` add:

```python
DeviceLabel = Annotated[str, StringConstraints(max_length=80, strip_whitespace=True)]
```

and add `device_label: DeviceLabel | None = None` as the last field of `RegisterRequest`, `LoginRequest`, and `RefreshTokenRequest`.

- [ ] **Step 5: Rewrite AuthService**

Replace `app/services/auth_service.py` with:

```python
from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import logging
from typing import TypedDict
import uuid

from pydantic import TypeAdapter
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy.exc import IntegrityError

from app.core.config import get_settings
from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import decode_token
from app.core.security import dummy_password_hash
from app.core.security import generate_refresh_token
from app.core.security import hash_password
from app.core.security import hash_refresh_token
from app.core.security import needs_rehash
from app.core.security import verify_password
from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.repositories.protocols import RefreshTokenRepositoryProtocol
from app.repositories.protocols import UserRepositoryProtocol
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError

logger = logging.getLogger(__name__)

INVALID_CREDENTIALS = "Invalid email or password."
INVALID_REFRESH_TOKEN = "Invalid or expired refresh token."


class TokenPairPayload(TypedDict):
    access_token: str
    refresh_token: str
    token_type: str


SUBJECT_UUID_ADAPTER = TypeAdapter(uuid.UUID)


def _utc_now() -> datetime:
    return datetime.now(UTC)


class AuthService:
    def __init__(
        self,
        user_repository: UserRepositoryProtocol,
        refresh_token_repository: RefreshTokenRepositoryProtocol,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._user_repository = user_repository
        self._refresh_token_repository = refresh_token_repository
        self._clock = clock or _utc_now

    def register(
        self,
        email: str,
        password: str,
        display_name: str,
        device_label: str | None = None,
    ) -> TokenPairPayload:
        existing_user = self._user_repository.get_by_email(email)
        if existing_user is not None:
            raise ConflictError("Email is already registered.")

        user = User(
            email=email,
            password_hash=hash_password(password),
            display_name=display_name,
        )
        self._user_repository.add(user)

        try:
            self._user_repository.commit()
        except IntegrityError as exc:
            self._user_repository.rollback()
            raise ConflictError("Email is already registered.") from exc

        self._user_repository.refresh(user)
        logger.info("User registered: %s", user.id)
        return self._issue_token_pair(user, family_id=uuid.uuid4(), device_label=device_label)

    def login(
        self,
        email: str,
        password: str,
        device_label: str | None = None,
    ) -> TokenPairPayload:
        user = self._user_repository.get_by_email(email)
        if user is None:
            # Burn the same hashing cost as a real user so timing does not
            # reveal whether the email exists.
            verify_password(password, dummy_password_hash())
            raise AuthenticationError(INVALID_CREDENTIALS)

        if not verify_password(password, user.password_hash):
            raise AuthenticationError(INVALID_CREDENTIALS)

        if needs_rehash(user.password_hash):
            user.password_hash = hash_password(password)
            self._user_repository.commit()

        return self._issue_token_pair(user, family_id=uuid.uuid4(), device_label=device_label)

    def refresh(self, refresh_token: str, device_label: str | None = None) -> TokenPairPayload:
        now = self._clock()
        token = self._refresh_token_repository.get_by_hash(hash_refresh_token(refresh_token))
        if token is None:
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        if token.revoked_at is not None:
            self._refresh_token_repository.revoke_family(token.family_id, now=now)
            self._refresh_token_repository.commit()
            logger.warning(
                "refresh_token_reuse family=%s user=%s", token.family_id, token.user_id
            )
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        if token.expires_at <= now or token.family_expires_at <= now:
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        user = self._user_repository.get_by_id(token.user_id)
        if user is None:
            raise AuthenticationError("User not found.")

        wire_token, token_hash = generate_refresh_token()
        successor = RefreshToken(
            user_id=user.id,
            token_hash=token_hash,
            family_id=token.family_id,
            device_label=device_label or token.device_label,
            issued_at=now,
            expires_at=now + timedelta(days=get_settings().refresh_token_expire_days),
            family_expires_at=token.family_expires_at,
        )
        token.last_used_at = now
        self._refresh_token_repository.revoke(token, now=now, replaced_by=successor)
        self._refresh_token_repository.commit()

        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": wire_token,
            "token_type": "bearer",
        }

    def logout(self, refresh_token: str) -> None:
        token = self._refresh_token_repository.get_by_hash(hash_refresh_token(refresh_token))
        if token is None or token.revoked_at is not None:
            return
        self._refresh_token_repository.revoke(token, now=self._clock())
        self._refresh_token_repository.commit()

    def get_user_from_access_token(self, access_token: str) -> User:
        try:
            payload = decode_token(access_token, expected_token_type=TOKEN_TYPE_ACCESS)
        except TokenValidationError as exc:
            raise AuthenticationError(str(exc)) from exc
        user_id = self._parse_subject(payload.get("sub"))
        user = self._user_repository.get_by_id(user_id)
        if user is None:
            raise AuthenticationError("User not found.")
        return user

    def _parse_subject(self, subject: object) -> uuid.UUID:
        if not isinstance(subject, str) or not subject:
            raise AuthenticationError("Invalid token subject.")

        try:
            return SUBJECT_UUID_ADAPTER.validate_python(subject)
        except PydanticValidationError as exc:
            raise AuthenticationError("Invalid token subject.") from exc

    def _issue_token_pair(
        self,
        user: User,
        *,
        family_id: uuid.UUID,
        device_label: str | None,
    ) -> TokenPairPayload:
        settings = get_settings()
        now = self._clock()
        wire_token, token_hash = generate_refresh_token()
        self._refresh_token_repository.add(
            RefreshToken(
                user_id=user.id,
                token_hash=token_hash,
                family_id=family_id,
                device_label=device_label,
                issued_at=now,
                expires_at=now + timedelta(days=settings.refresh_token_expire_days),
                family_expires_at=now + timedelta(days=settings.refresh_token_family_max_days),
            )
        )
        self._refresh_token_repository.commit()
        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": wire_token,
            "token_type": "bearer",
        }
```

- [ ] **Step 6: Remove JWT refresh tokens from security.py**

Delete `TOKEN_TYPE_REFRESH` and `create_refresh_token`. Keep `_create_token` (still used by `create_access_token`).

- [ ] **Step 7: Wire dependencies and the router**

In `app/core/dependencies/auth.py`:

```python
from app.repositories.refresh_token_repository import RefreshTokenRepository


def get_refresh_token_repository(db: Session = Depends(get_db)) -> RefreshTokenRepository:
    return RefreshTokenRepository(db)


def get_auth_service(
    user_repository: UserRepository = Depends(get_user_repository),
    refresh_token_repository: RefreshTokenRepository = Depends(get_refresh_token_repository),
) -> AuthService:
    return AuthService(
        user_repository=user_repository,
        refresh_token_repository=refresh_token_repository,
    )
```

Export `get_refresh_token_repository` from `app/core/dependencies/__init__.py` (import and `__all__`).

In `app/api/auth.py`: pass `device_label=payload.device_label` in `register`, `login`, and `refresh` (`auth_service.refresh(payload.refresh_token, device_label=payload.device_label)`), and replace `logout` with:

```python
@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    payload: RefreshTokenRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> Response:
    auth_service.logout(payload.refresh_token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
```

- [ ] **Step 8: Run the unit and QA suites**

Run: `python -m pytest tests/unit/test_auth_service.py tests/unit/test_security.py tests/unit/test_dependencies.py tests/qa/test_auth_qa.py -q`
Expected: all pass. Then `python -m pytest -q` for the full suite; everything that passed before still passes (other QA suites obtain tokens through `register_user`, which now returns opaque refresh tokens).

- [ ] **Step 9: Commit**

```bash
git add app/services/auth_service.py app/core/security.py app/schemas/auth.py app/core/dependencies app/api/auth.py tests/unit/test_auth_service.py tests/unit/test_security.py tests/qa/test_auth_qa.py
git commit -m "feat(backend): rotate and revoke opaque refresh tokens, rehash legacy passwords"
```

---

### Task 7: In-process rate limiter

**Files:**
- Create: `app/core/rate_limit.py`
- Test: `tests/unit/test_rate_limit.py` (new)

**Interfaces:**
- Produces: `RateLimitDecision(allowed: bool, retry_after_seconds: int)`, `RateLimiterProtocol.check(bucket, key, *, limit, window_seconds, now) -> RateLimitDecision`, `InMemoryRateLimiter`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/test_rate_limit.py
from app.core.rate_limit import InMemoryRateLimiter


def test_allows_up_to_limit_then_rejects_with_retry_after() -> None:
    limiter = InMemoryRateLimiter()

    for i in range(3):
        decision = limiter.check("login", "1.2.3.4", limit=3, window_seconds=60, now=100.0 + i)
        assert decision.allowed is True
        assert decision.retry_after_seconds == 0

    rejected = limiter.check("login", "1.2.3.4", limit=3, window_seconds=60, now=110.0)
    assert rejected.allowed is False
    assert rejected.retry_after_seconds == 50


def test_window_slides_and_old_events_expire() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "k", limit=1, window_seconds=10, now=0.0)

    assert limiter.check("login", "k", limit=1, window_seconds=10, now=9.9).allowed is False
    assert limiter.check("login", "k", limit=1, window_seconds=10, now=10.1).allowed is True


def test_buckets_and_keys_are_isolated() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "a", limit=1, window_seconds=60, now=0.0)

    assert limiter.check("login", "b", limit=1, window_seconds=60, now=0.0).allowed is True
    assert limiter.check("register", "a", limit=1, window_seconds=60, now=0.0).allowed is True
    assert limiter.check("login", "a", limit=1, window_seconds=60, now=0.0).allowed is False


def test_retry_after_is_at_least_one_second() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "k", limit=1, window_seconds=10, now=0.0)

    assert limiter.check("login", "k", limit=1, window_seconds=10, now=9.99).retry_after_seconds == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_rate_limit.py -q`
Expected: ImportError.

- [ ] **Step 3: Implement**

```python
# app/core/rate_limit.py
"""Sliding-window rate limiter kept in process memory.

Good enough for a single backend instance. Swap the implementation behind
`RateLimiterProtocol` (for example Redis) when running more than one.
"""

from collections import deque
from dataclasses import dataclass
import math
import threading
from typing import Protocol


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int


class RateLimiterProtocol(Protocol):
    def check(
        self,
        bucket: str,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float,
    ) -> RateLimitDecision: ...


class InMemoryRateLimiter:
    def __init__(self) -> None:
        self._events: dict[tuple[str, str], deque[float]] = {}
        self._lock = threading.Lock()

    def check(
        self,
        bucket: str,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float,
    ) -> RateLimitDecision:
        with self._lock:
            events = self._events.setdefault((bucket, key), deque())
            cutoff = now - window_seconds
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= limit:
                retry_after = math.ceil(events[0] + window_seconds - now)
                return RateLimitDecision(allowed=False, retry_after_seconds=max(retry_after, 1))
            events.append(now)
            return RateLimitDecision(allowed=True, retry_after_seconds=0)
```

- [ ] **Step 4: Run the tests**

Run: `python -m pytest tests/unit/test_rate_limit.py -q`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add app/core/rate_limit.py tests/unit/test_rate_limit.py
git commit -m "feat(backend): in-memory sliding window rate limiter"
```

---

### Task 8: Rate limits on the auth endpoints

**Files:**
- Modify: `app/services/exceptions.py`
- Modify: `app/api/exception_handlers.py`
- Create: `app/core/dependencies/rate_limit.py`
- Modify: `app/core/dependencies/__init__.py`
- Modify: `app/api/auth.py`
- Modify: `tests/qa/conftest.py`
- Test: `tests/qa/test_rate_limit_qa.py` (new)

**Interfaces:**
- Consumes: `InMemoryRateLimiter`, `RateLimiterProtocol` (Task 7); settings (Task 1).
- Produces: `RateLimitedError(ServiceError)` with `retry_after_seconds: int`; dependencies `get_rate_limiter()`, `limit_login(request, payload, limiter) -> LoginRequest`, `limit_register(request, limiter) -> None`, `limit_refresh(request, limiter) -> None`; 429 responses carry `Retry-After`.

- [ ] **Step 1: Write the failing QA tests**

```python
# tests/qa/test_rate_limit_qa.py
from fastapi.testclient import TestClient


def test_login_is_rate_limited_per_email(client: TestClient, register_user) -> None:
    user = register_user()
    other = register_user()

    for _ in range(5):
        response = client.post(
            "/v1/auth/login",
            json={"email": user["email"], "password": "wrong"},
        )
        assert response.status_code == 401

    limited = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"]},
    )
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert limited.json()["detail"].startswith("Too many requests. Try again in ")

    unaffected = client.post(
        "/v1/auth/login",
        json={"email": other["email"], "password": other["password"]},
    )
    assert unaffected.status_code == 200


def test_register_is_rate_limited_per_ip(client: TestClient) -> None:
    for i in range(5):
        response = client.post(
            "/v1/auth/register",
            json={
                "email": f"burst{i}@example.com",
                "password": "strongpass123",
                "display_name": "Burst",
            },
        )
        assert response.status_code == 201

    limited = client.post(
        "/v1/auth/register",
        json={"email": "burst5@example.com", "password": "strongpass123", "display_name": "Burst"},
    )
    assert limited.status_code == 429


def test_rate_limit_can_be_disabled(
    client: TestClient, register_user, monkeypatch
) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("RATE_LIMIT_ENABLED", "false")
    get_settings.cache_clear()
    user = register_user()

    for _ in range(7):
        response = client.post(
            "/v1/auth/login",
            json={"email": user["email"], "password": "wrong"},
        )
        assert response.status_code == 401
```

In `tests/qa/conftest.py`, inside the `client` fixture, add a fresh limiter override next to the `get_db` override:

```python
from app.core.dependencies.rate_limit import get_rate_limiter
from app.core.rate_limit import InMemoryRateLimiter

    limiter = InMemoryRateLimiter()
    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_rate_limiter] = lambda: limiter
```

Note: `register_user` counts against the `register_ip` bucket (5 per hour). Existing QA tests register at most two users per test, so they stay under the limit with a fresh limiter per test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/qa/test_rate_limit_qa.py -q`
Expected: ImportError for `app.core.dependencies.rate_limit`.

- [ ] **Step 3: Add the error and handler**

In `app/services/exceptions.py`:

```python
class RateLimitedError(ServiceError):
    def __init__(self, retry_after_seconds: int) -> None:
        self.retry_after_seconds = retry_after_seconds
        super().__init__(f"Too many requests. Try again in {retry_after_seconds} seconds.")
```

In `app/api/exception_handlers.py` add:

```python
from app.services.exceptions import RateLimitedError


async def _rate_limited_handler(_: Request, exc: Exception) -> Response:
    assert isinstance(exc, RateLimitedError)
    return JSONResponse(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        content={"detail": str(exc)},
        headers={"Retry-After": str(exc.retry_after_seconds)},
    )
```

and register it in `register_service_exception_handlers`: `app.add_exception_handler(RateLimitedError, _rate_limited_handler)`.

- [ ] **Step 4: Add the dependencies**

```python
# app/core/dependencies/rate_limit.py
import time

from fastapi import Depends
from fastapi import Request

from app.core.config import get_settings
from app.core.rate_limit import InMemoryRateLimiter
from app.core.rate_limit import RateLimiterProtocol
from app.schemas.auth import LoginRequest
from app.services.exceptions import RateLimitedError

_limiter: InMemoryRateLimiter | None = None


def get_rate_limiter() -> RateLimiterProtocol:
    global _limiter
    if _limiter is None:
        _limiter = InMemoryRateLimiter()
    return _limiter


def client_ip(request: Request) -> str:
    if get_settings().trust_proxy_headers:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return request.client.host if request.client is not None else "unknown"


def enforce_rate_limit(
    limiter: RateLimiterProtocol,
    bucket: str,
    key: str,
    *,
    limit: int,
    window_seconds: int,
) -> None:
    if not get_settings().rate_limit_enabled:
        return
    decision = limiter.check(
        bucket, key, limit=limit, window_seconds=window_seconds, now=time.monotonic()
    )
    if not decision.allowed:
        raise RateLimitedError(decision.retry_after_seconds)


def limit_login(
    request: Request,
    payload: LoginRequest,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> LoginRequest:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "login_ip",
        client_ip(request),
        limit=settings.rate_limit_login_per_ip,
        window_seconds=settings.rate_limit_window_seconds,
    )
    enforce_rate_limit(
        limiter,
        "login_email",
        payload.email,
        limit=settings.rate_limit_login_per_email,
        window_seconds=settings.rate_limit_window_seconds,
    )
    return payload


def limit_register(
    request: Request,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> None:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "register_ip",
        client_ip(request),
        limit=settings.rate_limit_register_per_ip,
        window_seconds=settings.rate_limit_register_window_seconds,
    )


def limit_refresh(
    request: Request,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> None:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "refresh_ip",
        client_ip(request),
        limit=settings.rate_limit_refresh_per_ip,
        window_seconds=settings.rate_limit_window_seconds,
    )
```

Export `get_rate_limiter`, `limit_login`, `limit_register`, `limit_refresh` from `app/core/dependencies/__init__.py`.

- [ ] **Step 5: Apply them in the router**

In `app/api/auth.py`:

```python
from app.core.dependencies import limit_login
from app.core.dependencies import limit_refresh
from app.core.dependencies import limit_register


@router.post(
    "/register",
    response_model=TokenPair,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_register)],
)
def register(...)  # body unchanged from Task 6


@router.post("/login", response_model=TokenPair)
def login(
    payload: LoginRequest = Depends(limit_login),
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    token_pair = auth_service.login(
        email=payload.email,
        password=payload.password,
        device_label=payload.device_label,
    )
    return TokenPair.model_validate(token_pair)


@router.post("/refresh", response_model=TokenPair, dependencies=[Depends(limit_refresh)])
def refresh(...)  # body unchanged from Task 6
```

- [ ] **Step 6: Run the QA suites**

Run: `python -m pytest tests/qa -q`
Expected: all pass, including the three new rate-limit tests.

- [ ] **Step 7: Commit**

```bash
git add app/services/exceptions.py app/api/exception_handlers.py app/core/dependencies app/api/auth.py tests/qa/conftest.py tests/qa/test_rate_limit_qa.py
git commit -m "feat(backend): rate limit login, register and refresh"
```

---

### Task 9: Cap points per session

**Files:**
- Modify: `app/repositories/protocols.py` (`SessionPointRepositoryProtocol.count_by_session`)
- Modify: `app/repositories/session_point_repository.py`
- Modify: `app/services/session_service.py` (`upload_points_batch`)
- Modify: `tests/unit/test_session_service.py` (fake repository + one test)
- Modify: `tests/qa/test_sessions_qa.py` (one test)

**Interfaces:**
- Produces: `SessionPointRepositoryProtocol.count_by_session(session_id) -> int`; `upload_points_batch` raises `ValidationError("Session point limit exceeded.")` when `existing + new > settings.max_points_per_session`.

- [ ] **Step 1: Write the failing unit test**

In `tests/unit/test_session_service.py` add to `FakeSessionPointRepository`:

```python
    def count_by_session(self, session_id):
        return len(self.offsets_by_session.get(session_id, set()))
```

and append:

```python
def test_upload_points_batch_rejects_when_session_cap_exceeded(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("MAX_POINTS_PER_SESSION", "3")
    get_settings.cache_clear()
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    point_repo.offsets_by_session[draft_session.id] = {0, 1000}
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    with pytest.raises(ValidationError, match=r"Session point limit exceeded."):
        service.upload_points_batch(
            session_id=draft_session.id,
            user_id=user_id,
            points=[
                SessionPointInput(t_offset_ms=2000, latitude=50.0, longitude=-122.0),
                SessionPointInput(t_offset_ms=3000, latitude=50.0, longitude=-122.0),
            ],
        )
    assert point_repo.batches == []
```

- [ ] **Step 2: Write the failing QA test**

Append to `tests/qa/test_sessions_qa.py`:

```python
def test_sessions_points_batch_rejects_over_cap(
    client: TestClient,
    register_user,
    monkeypatch,
) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("MAX_POINTS_PER_SESSION", "2")
    get_settings.cache_clear()
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    session_id = client.post("/v1/sessions", json={}, headers=headers).json()["id"]

    points = [
        {"t_offset_ms": i * 1000, "latitude": 50.0, "longitude": -122.0} for i in range(3)
    ]
    response = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={"points": points},
        headers=headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Session point limit exceeded."
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest tests/unit/test_session_service.py::test_upload_points_batch_rejects_when_session_cap_exceeded tests/qa/test_sessions_qa.py::test_sessions_points_batch_rejects_over_cap -q`
Expected: both fail (no cap enforced).

- [ ] **Step 4: Implement**

Protocol, add to `SessionPointRepositoryProtocol`:

```python
    def count_by_session(self, session_id: uuid.UUID) -> int: ...
```

Repository:

```python
    def count_by_session(self, session_id: uuid.UUID) -> int:
        stmt = (
            select(func.count())
            .select_from(SessionPoint)
            .where(SessionPoint.session_id == session_id)
        )
        return int(self._db.scalar(stmt) or 0)
```

(import `func` from `sqlalchemy`).

Service, in `upload_points_batch` after `deduped_points = ...`:

```python
        existing_count = self._session_point_repository.count_by_session(ride_session.id)
        if existing_count + len(deduped_points) > get_settings().max_points_per_session:
            raise ValidationError("Session point limit exceeded.")
```

(import `from app.core.config import get_settings`).

- [ ] **Step 5: Run the session suites**

Run: `python -m pytest tests/unit/test_session_service.py tests/qa/test_sessions_qa.py -q`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/repositories/protocols.py app/repositories/session_point_repository.py app/services/session_service.py tests/unit/test_session_service.py tests/qa/test_sessions_qa.py
git commit -m "feat(backend): cap stored points per session"
```

---

### Task 10: Debug-gated docs and log hygiene

**Files:**
- Modify: `app/main.py`
- Modify: `tests/qa/test_system_qa.py`

**Interfaces:**
- Produces: `create_app() -> FastAPI` in `app/main.py`; module-level `app = create_app()` stays so `uvicorn app.main:app` and the QA fixtures keep working. `/docs`, `/redoc`, `/openapi.json` return 404 unless `DEBUG=true`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/qa/test_system_qa.py`:

```python
import pytest

from app.core.config import get_settings
from app.main import create_app


def test_docs_hidden_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DEBUG", raising=False)
    get_settings.cache_clear()
    with TestClient(create_app()) as test_client:
        assert test_client.get("/docs").status_code == 404
        assert test_client.get("/openapi.json").status_code == 404


def test_docs_available_in_debug(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEBUG", "true")
    get_settings.cache_clear()
    with TestClient(create_app()) as test_client:
        assert test_client.get("/docs").status_code == 200
        assert test_client.get("/openapi.json").status_code == 200
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/qa/test_system_qa.py -q`
Expected: ImportError for `create_app`.

- [ ] **Step 3: Implement**

Replace the `app = FastAPI(...)` block and the calls after it in `app/main.py` with:

```python
def create_app() -> FastAPI:
    settings = get_settings()
    application = FastAPI(
        title="GoofyRider API",
        version="0.1.0",
        description="Backend API for the GoofyRider snowboarding tracker.",
        lifespan=lifespan,
        docs_url="/docs" if settings.debug else None,
        redoc_url="/redoc" if settings.debug else None,
        openapi_url="/openapi.json" if settings.debug else None,
    )
    register_service_exception_handlers(application)
    application.include_router(health_router)
    application.include_router(api_router)

    @application.get("/", include_in_schema=False)
    async def root() -> dict[str, str]:
        return {"message": "GoofyRider API is running"}

    return application


app = create_app()
```

Log hygiene is already complete after Task 6 (`auth_service.py` logs user ids only); confirm with `grep -n "email" app/services/auth_service.py` showing no `logger` line that includes an email.

- [ ] **Step 4: Run the system suite and the whole suite**

Run: `python -m pytest tests/qa/test_system_qa.py -q && python -m pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/main.py tests/qa/test_system_qa.py
git commit -m "feat(backend): hide API docs unless DEBUG is set"
```

---

### Task 11: Backend quality gates

**Files:** none new.

- [ ] **Step 1: Format and lint touched files**

Run: `ruff format app/core app/services/auth_service.py app/services/exceptions.py app/api app/repositories app/models/refresh_token.py tests/unit/test_auth_service.py tests/unit/test_security.py tests/unit/test_rate_limit.py tests/unit/test_config.py tests/unit/repositories/test_refresh_token_repository.py tests/qa/test_auth_qa.py tests/qa/test_rate_limit_qa.py tests/qa/test_system_qa.py tests/qa/conftest.py`
then `ruff check app/core app/services/auth_service.py app/services/exceptions.py app/api app/repositories app/models/refresh_token.py tests`
Expected: no errors in the files this plan touched. Pre-existing errors in `models/__init__.py`, `slopes_import_service.py`, and `session_analyzer.py` (audit H1) are handled by the cleanup sub-project; if `ruff check .` still lists only those, the gate for this plan is satisfied. Note: adding `RefreshToken` to `models/__init__.py` in the correct sorted position must not add a new isort error.

- [ ] **Step 2: Type-check**

Run: `mypy`
Expected: no errors in files touched by this plan; only the pre-existing errors from audit H1 remain.

- [ ] **Step 3: Full test run**

Run: `python -m pytest -q`
Expected: all pass.

- [ ] **Step 4: Commit any formatting changes**

```bash
git add -A app tests
git commit -m "style(backend): ruff format after security hardening"
```
