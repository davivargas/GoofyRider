# Security hardening design (2026-09-12)

Status: approved design, awaiting written-spec review before planning.
Branch: `fable-review`. Source findings: `docs/audit/2026-09-12-project-audit.md`
section 7 (S1 to S14).

## 1. Goal and scope

Harden Fall Line so it can be handed to friends without an obvious way to
hijack an account, brute-force a login, read tokens out of a backup, or ship
a debug-signed build, while keeping the deployment local-only (docker compose
on one machine) for now.

In scope:

- Refresh-token lifecycle: server-side storage, rotation, reuse detection,
  revocation on logout (S1, S6).
- Argon2id password hashing with transparent re-hash of PBKDF2 users (S2).
- Uniform-time login (S4).
- Rate limiting on the auth endpoints and a storage cap on point uploads (S3).
- Docs and OpenAPI gated behind a debug flag (S5).
- No personal data in backend logs (S7).
- README and example files stop instructing reviewers to ship real keys (S8).
- Android: HTTPS-only network policy with a debug override, backups disabled,
  release signing from a gitignored keystore, explicit R8 shrinking and
  obfuscation guidance (S9, S10, S11).
- Mobile: `device_label` on login and register, 429 handling, and moving
  ordinary preferences from secure storage to `shared_preferences` (new
  CLAUDE.md rule; the secure-storage misuse is audit finding M10).

Out of scope (deferred, with notes in section 10):

- HTTPS termination, reverse proxy, security headers (S13 beyond the
  loopback bind, S14): decided when a host is chosen.
- Acting on `is_mocked` points (S12): only matters once leaderboards exist.
- Application id rename: owned by the `rename/fall-line` branch.
- Email verification, password reset, account deletion: product features,
  not hardening.

## 2. Decisions already taken

| Decision | Choice | Why |
|---|---|---|
| Token model | Opaque refresh tokens stored hashed in Postgres; access tokens stay short-lived JWTs | Revocable, simple to reason about, one table |
| Access token lifetime | 15 minutes (was 30) | Logout cannot revoke access tokens; short life bounds the window |
| Refresh token lifetime | 30 days sliding (each rotation issues a fresh 30-day token), absolute cap 90 days per family | Friends will not log in daily; the cap bounds a silently stolen token |
| Hashing | Argon2id, m=64 MiB, t=3, p=4 | OWASP 2026 baseline |
| Limiter | In-process sliding window behind a protocol | No Redis for a single container; swappable later |
| Infrastructure | No new services | Local-only hosting |

## 3. Backend design

### 3.1 Model and migration

New model `app/models/refresh_token.py`:

```
refresh_tokens
  id                UUID PK
  user_id           UUID FK users.id ON DELETE CASCADE, indexed
  token_hash        String(64) UNIQUE NOT NULL     -- hex SHA-256 of the wire token
  family_id         UUID NOT NULL, indexed         -- shared across rotations
  device_label      String(80) NULL
  issued_at         timestamptz NOT NULL default now()
  expires_at        timestamptz NOT NULL
  family_expires_at timestamptz NOT NULL           -- absolute cap for the family
  last_used_at      timestamptz NULL
  revoked_at        timestamptz NULL
  replaced_by_id    UUID NULL FK refresh_tokens.id
```

Alembic revision `0013_refresh_tokens` creates the table and indexes
(`ix_refresh_tokens_user_id`, `ix_refresh_tokens_family_id`,
`uq_refresh_tokens_token_hash`). Downgrade drops the table.

The wire token is `base64url(secrets.token_bytes(32))` without padding. Only
its SHA-256 hex is stored; the plaintext never touches the database or logs.

### 3.2 Repository

Add to `app/repositories/protocols.py`:

```
class RefreshTokenRepositoryProtocol(Protocol):
    def add(self, token: RefreshToken) -> None
    def get_by_hash(self, token_hash: str) -> RefreshToken | None
    def revoke(self, token: RefreshToken, *, now: datetime, replaced_by: RefreshToken | None = None) -> None
    def revoke_family(self, family_id: uuid.UUID, *, now: datetime) -> int
    def delete_expired(self, *, now: datetime) -> int
    def commit(self) -> None
    def rollback(self) -> None
```

Concrete `RefreshTokenRepository(SqlAlchemyRepository)` in
`app/repositories/refresh_token_repository.py`. `revoke_family` is a single
`UPDATE ... WHERE family_id = :f AND revoked_at IS NULL`. `delete_expired`
removes rows whose `family_expires_at < now` or whose `expires_at < now - 7 days`
(keeps a short audit tail of rotated tokens).

### 3.3 Security helpers (`app/core/security.py`)

- `hash_password` produces Argon2id via the `argon2-cffi` `PasswordHasher`
  configured from settings (`argon2_memory_kib`, `argon2_time_cost`,
  `argon2_parallelism`). Output is the standard `$argon2id$...` string.
- `verify_password` dispatches on prefix: `$argon2id$` uses Argon2 verify;
  `pbkdf2_sha256$` uses the existing PBKDF2 branch. Anything else is False.
- `needs_rehash(stored_hash) -> bool`: True for PBKDF2 hashes and for Argon2
  hashes whose parameters differ from current settings.
- `DUMMY_PASSWORD_HASH`: an Argon2id hash computed once at import from a
  random secret, used to equalise timing when the user does not exist.
- `generate_refresh_token() -> tuple[str, str]` returns `(wire_token,
  token_hash)`.
- `create_access_token(subject)` adds `iss=settings.jwt_issuer`
  (`fall-line-api`), `aud=settings.jwt_audience` (`fall-line-mobile`), and
  `jti=uuid4().hex`. `decode_token` passes `issuer` and `audience` to
  `jwt.decode`; missing or wrong values raise `TokenValidationError`.
- `create_refresh_token` and `TOKEN_TYPE_REFRESH` are removed; JWT refresh
  tokens are no longer issued or accepted.

### 3.4 AuthService

Constructor gains `refresh_token_repository: RefreshTokenRepositoryProtocol`
and `clock: Callable[[], datetime]` (default `datetime.now(UTC)`) for tests.

- `register(email, password, display_name, device_label)`: unchanged flow,
  then `_issue_token_pair(user, family_id=uuid4(), device_label)`.
- `login(email, password, device_label)`: load user; if missing, run
  `verify_password(password, DUMMY_PASSWORD_HASH)` and raise
  `AuthenticationError("Invalid email or password.")`; if present and the
  password verifies and `needs_rehash`, set `user.password_hash =
  hash_password(password)` and commit; issue a pair with a new family.
- `refresh(wire_token, device_label)`:
  1. `token = repo.get_by_hash(sha256(wire_token))`; None raises 401.
  2. `token.revoked_at is not None` means reuse: `revoke_family`, commit,
     log `refresh_token_reuse family=<id> user=<id>` at WARNING, raise 401.
  3. `token.expires_at < now` or `token.family_expires_at < now` raises 401.
  4. Create successor with the same `family_id` and `family_expires_at`,
     `expires_at = now + refresh_token_expire_days`; `repo.revoke(token,
     replaced_by=successor)`; `token.last_used_at = now`; commit; return the
     new pair.
  Steps 1 to 4 run inside one transaction; a concurrent second refresh of the
  same token hits the unique hash on insert or sees `revoked_at` and gets
  401, which is the intended outcome.
- `logout(wire_token)`: look up by hash; if found and not revoked, revoke
  (no successor) and commit. Always succeeds (204) so a client can clear
  state regardless.
- `get_user_from_access_token` unchanged apart from the new claims.
- Logging: `logger.info("User registered: %s", user.id)`, failed logins log
  nothing beyond the limiter's own counters, refresh reuse logs family and
  user ids only.

`TokenPairPayload` and the `TokenPair` schema are unchanged on the wire.
`LoginRequest`, `RegisterRequest`, and `RefreshTokenRequest` gain
`device_label: str | None` (max 80, stripped). `RefreshTokenRequest.refresh_token`
keeps `NonEmptyToken`.

### 3.5 Rate limiting (`app/core/rate_limit.py`)

```
class RateLimiterProtocol(Protocol):
    def check(self, bucket: str, key: str, *, limit: int, window_seconds: int, now: float) -> RateLimitDecision

@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int
```

`InMemoryRateLimiter` keeps `dict[(bucket, key), deque[float]]` of request
timestamps, prunes timestamps older than the window on each check, and is
guarded by a `threading.Lock` (sync routes run on a thread pool). A
module-level instance is created lazily by `get_rate_limiter()` in
`app/core/dependencies/rate_limit.py`; tests override the dependency with a
fresh instance.

Dependencies applied per route:

| Route | Buckets |
|---|---|
| `POST /auth/login` | `login_ip` (10 per 300 s per client IP), `login_email` (5 per 300 s per normalised email) |
| `POST /auth/register` | `register_ip` (5 per 3600 s) |
| `POST /auth/refresh` | `refresh_ip` (30 per 300 s) |

Client IP is `request.client.host`; `X-Forwarded-For` is honoured only when
`settings.trust_proxy_headers` is true (default False, to be enabled with the
reverse proxy later). The email bucket is checked inside the router
dependency after body parsing; both checks happen before the service runs.

Limits are settings: `rate_limit_login_per_ip`, `rate_limit_login_per_email`,
`rate_limit_register_per_ip`, `rate_limit_refresh_per_ip`, each a
`PositiveInt`, and `rate_limit_window_seconds` (`PositiveInt`, default 300)
with `rate_limit_register_window_seconds` (default 3600).
`rate_limit_enabled: bool = True` lets QA tests that hammer login disable it.

Exceeding a limit raises `RateLimitedError(ServiceError)` carrying
`retry_after_seconds`; `exception_handlers.py` maps it to 429 with a
`Retry-After` header and `{"detail": "Too many requests. Try again in N
seconds."}`.

Point upload cap: `SessionService.upload_points_batch` counts existing points
(new `SessionPointRepositoryProtocol.count_by_session`) and raises
`ValidationError("Session point limit exceeded.")` when
`existing + new > settings.max_points_per_session` (`PositiveInt`, default
200000, about 55 hours at 1 Hz).

### 3.6 Settings and wiring

`AppSettings` additions, all read via `get_settings().<name>`:

| Setting | Type | Default |
|---|---|---|
| `debug` | bool | False |
| `jwt_issuer` | str | `fall-line-api` |
| `jwt_audience` | str | `fall-line-mobile` |
| `access_token_expire_minutes` | PositiveInt | 15 (changed) |
| `refresh_token_expire_days` | PositiveInt | 30 (changed) |
| `refresh_token_family_max_days` | PositiveInt | 90 |
| `argon2_memory_kib` | PositiveInt | 65536 |
| `argon2_time_cost` | PositiveInt | 3 |
| `argon2_parallelism` | PositiveInt | 4 |
| `rate_limit_enabled` | bool | True |
| `rate_limit_window_seconds` | PositiveInt | 300 |
| `rate_limit_register_window_seconds` | PositiveInt | 3600 |
| `rate_limit_login_per_ip` | PositiveInt | 10 |
| `rate_limit_login_per_email` | PositiveInt | 5 |
| `rate_limit_register_per_ip` | PositiveInt | 5 |
| `rate_limit_refresh_per_ip` | PositiveInt | 30 |
| `trust_proxy_headers` | bool | False |
| `max_points_per_session` | PositiveInt | 200000 |

A validator enforces `refresh_token_family_max_days >= refresh_token_expire_days`.
`docker-compose.yml` wires every new variable with `${VAR:-default}`; the
`db` service binds its port to the loopback interface only
(`127.0.0.1:5432:5432`) so the host workflow (`uvicorn --reload`, the test
suite, `alembic upgrade head`) keeps working while nothing on the LAN can
reach Postgres. The backend keeps `8000` open so a phone on the LAN can use
it.
`.env.example` gains the new keys with comments.

`main.py`: `FastAPI(docs_url="/docs" if settings.debug else None, ...)` for
docs, redoc, and openapi. The `root` endpoint stays.

`pyproject.toml`: add `argon2-cffi>=23.1`. No other dependency.

Tests: `tests/conftest.py` sets `ARGON2_MEMORY_KIB=8192`, `ARGON2_TIME_COST=1`
so the suite stays fast; `tests/qa/conftest.py` adds `refresh_tokens` to the
truncate list and overrides the limiter dependency per test.

## 4. Mobile design

- `AuthApi.login/register/refresh` send `device_label` (built once in
  `auth_repository_impl.dart` from `Platform.operatingSystem` plus the model
  reported by a tiny `MethodChannel` call on the existing native bridge, e.g.
  `Pixel 8 / Android 15`; falls back to `Android`).
- `AuthTokenInterceptor` behaviour is already correct for rotation: it stores
  the new pair from the refresh response and serialises concurrent refreshes.
  Add one guard: when the refresh endpoint returns 401, treat it as revoked
  and call `onAuthReset` even for `preserveAuthOnFailure` requests (a revoked
  family cannot recover by waiting).
- `mapDioException`: 429 becomes a `NetworkFailure` with the server detail
  and the parsed `Retry-After`; the login screen shows it verbatim.
- Preferences: new `core/storage/app_preferences.dart` wrapping
  `shared_preferences` with typed getters and setters for speed unit,
  distance unit, and the onboarding flag. `DistanceUnitPreferenceController`,
  `SpeedUnitPreferenceController`, and `GpsWarmupPermissionPreference` read
  from it. A one-time migration reads the three legacy secure-storage keys,
  copies any value into `shared_preferences`, and deletes the legacy keys.
  The two unit controllers collapse into one generic
  `EnumPreferenceController<T>` to remove the copy-paste (audit M10).
- `TokenStorage` is unchanged. Nothing else in the app touches tokens.

## 5. Android build hardening

- `android/app/src/main/res/xml/network_security_config.xml`:
  `<base-config cleartextTrafficPermitted="false">` with system trust anchors.
- `android/app/src/debug/res/xml/network_security_config.xml`:
  `cleartextTrafficPermitted="true"` so `http://10.0.2.2:8000` and LAN
  backends keep working in debug builds. The manifest references
  `@xml/network_security_config`; source-set precedence picks the debug file
  automatically.
- Manifest: `android:allowBackup="false"`,
  `android:dataExtractionRules="@xml/data_extraction_rules"` (excludes all
  app data from cloud and device-to-device transfer),
  `android:fullBackupContent="false"` for pre-31 devices.
- `build.gradle.kts`: read `key.properties` (gitignored, documented in
  `android/key.properties.example`) into a `release` signing config; when the
  file is absent, fall back to the debug signing config and print a Gradle
  warning so local `--release` runs still work. Release build type sets
  `isMinifyEnabled = true`, `isShrinkResources = true`, and
  `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),
  "proguard-rules.pro")`; `proguard-rules.pro` keeps the Flutter embedding
  and `com.google.android.gms.location` classes.
- README: release build command documented as
  `flutter build apk --release --obfuscate --split-debug-info=build/symbols
  --dart-define=API_BASE_URL=https://... --dart-define-from-file=mapbox.json`;
  the "pre-populated keys" paragraph is replaced with instructions to copy
  `.env.example` and `mapbox.json.example`.
- `.gitignore`: `android/key.properties`, `android/*.jks`, `android/*.keystore`.

## 6. Error handling summary

| Situation | Response |
|---|---|
| Unknown, expired, or revoked refresh token | 401 `Invalid or expired refresh token.` |
| Refresh token reuse | family revoked, 401 (same message) |
| Access token with wrong `iss`/`aud` | 401 `Invalid token.` |
| Login with unknown email or wrong password | 401 `Invalid email or password.` (uniform timing) |
| Rate limit exceeded | 429 with `Retry-After` |
| Point cap exceeded | 400 `Session point limit exceeded.` |
| Docs requested with `debug=false` | 404 |

## 7. Testing

Backend unit (`tests/unit`):

- `test_security.py`: Argon2 hash and verify round trip; PBKDF2 hash still
  verifies; `needs_rehash` true for PBKDF2 and for changed Argon2 params;
  access token carries `iss`, `aud`, `jti`; decode rejects wrong issuer and
  audience; `generate_refresh_token` returns a 43-char base64url token and a
  64-hex hash.
- `test_auth_service.py`: login re-hashes a PBKDF2 user; login with unknown
  user calls the dummy verify (assert via a monkeypatched counter); refresh
  rotates and revokes the old token; refresh of a revoked token revokes the
  whole family and raises; refresh past `expires_at` and past
  `family_expires_at` raises; logout revokes and is idempotent.
- `test_rate_limit.py`: allows up to the limit, rejects the next, computes
  `retry_after`, prunes after the window, isolates buckets and keys.
- `test_config.py`: new settings parse, family cap validator, `debug`
  default False.
- `tests/unit/repositories/test_refresh_token_repository.py`: add, lookup by
  hash, `revoke_family` count, `delete_expired`.

Backend QA (`tests/qa/test_auth_qa.py`, new `test_rate_limit_qa.py`):

- register, refresh, old refresh token rejected, new one works.
- reuse of the rotated token returns 401 and the newest token is then also
  rejected (family revoked).
- logout then refresh returns 401.
- login six times with the wrong password for one email returns 429 with
  `Retry-After`; other emails are unaffected.
- `/docs` and `/openapi.json` are 404 with `DEBUG` unset and 200 with
  `DEBUG=true`.
- `device_label` is accepted and stored (assert via repository).
- point batch beyond `max_points_per_session` returns 400.

Mobile unit:

- `auth_token_interceptor_test.dart`: rotated refresh token is stored;
  refresh 401 resets auth even on preserved-auth requests.
- `api_error` mapping of 429 with `Retry-After`.
- `app_preferences_test.dart`: legacy secure-storage values migrate once and
  the legacy keys are deleted.

Quality gates per CLAUDE.md run before the branch is called done.

## 8. Migration and rollout

1. Land the backend change with migration 0013. Existing users keep their
   PBKDF2 hashes until their next login. Existing refresh JWTs are rejected,
   so every installed app re-logs once; the interceptor already handles that.
2. Land the mobile change. Old builds against the new backend still work
   (they send no `device_label`, which is optional).
3. Regenerate the Mapbox token and SkiAPI key once and update the local
   `.env` and `mapbox.json`, since both have been shared as "pre-populated".

## 9. Files touched (expected)

Backend: `app/models/refresh_token.py`, `app/models/__init__.py`,
`alembic/versions/0013_refresh_tokens.py`, `app/repositories/protocols.py`,
`app/repositories/refresh_token_repository.py`, `app/repositories/__init__.py`,
`app/repositories/session_point_repository.py`, `app/core/security.py`,
`app/core/rate_limit.py`, `app/core/dependencies/rate_limit.py`,
`app/core/dependencies/auth.py`, `app/core/config.py`, `app/api/auth.py`,
`app/api/exception_handlers.py`, `app/services/auth_service.py`,
`app/services/session_service.py`, `app/services/exceptions.py`,
`app/schemas/auth.py`, `app/main.py`, `pyproject.toml`, `docker-compose.yml`,
`.env.example`, tests listed in section 7.

Mobile: `lib/core/network/api_error.dart`,
`lib/core/network/auth_token_interceptor.dart`,
`lib/core/storage/app_preferences.dart` (new),
`lib/core/providers/*_preference_provider.dart`,
`lib/features/auth/data/auth_api.dart`,
`lib/features/auth/data/auth_repository_impl.dart`,
`lib/features/session/data/gps_warmup_permission_preference.dart`,
`pubspec.yaml` (`shared_preferences`), `android/app/src/main/AndroidManifest.xml`,
`android/app/src/main/res/xml/network_security_config.xml`,
`android/app/src/main/res/xml/data_extraction_rules.xml`,
`android/app/src/debug/res/xml/network_security_config.xml`,
`android/app/build.gradle.kts`, `android/app/proguard-rules.pro`,
`android/key.properties.example`, `.gitignore`, `README.md`, tests listed in
section 7.

## 10. Deferred: hosting checklist

When a host is chosen, the remaining audit items become a short follow-up:
Caddy or nginx terminating TLS in front of uvicorn; `trust_proxy_headers=true`;
`HSTS`, `X-Content-Type-Options`, `Referrer-Policy` headers at the proxy;
remove the backend `ports` mapping from the public interface; Postgres bound
to the compose network only; the limiter swapped for a Redis implementation
if more than one backend instance runs; backups of the Postgres volume.
