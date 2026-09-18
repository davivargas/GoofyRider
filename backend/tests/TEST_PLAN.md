# Fall Line Backend Testing Plan (Phase 1-3 Baseline, Future-Ready)

## 1. Test strategy in one page

We use two complementary paths:

- Unit path (`tests/unit`): fast logic validation (functions, validators, auth internals, dependency behavior).
- QA path (`tests/qa`): API-level behavior validation using realistic flows and HTTP contracts.

Why both:

- Unit tests isolate bugs quickly and make refactoring safe.
- QA tests prove that real requests still work end-to-end (auth + routing + validation + DB).
- Together they reduce regressions now and keep Phase 4+ changes safe.

## 2. Scope and quality goals

In scope now:

- system endpoints (`/`, `/health`)
- auth (`/v1/auth/*`)
- resorts and favorites (`/v1/resorts*`, `/v1/users/me/favorites*`)
- sessions (`/v1/sessions*`, `/v1/users/me/sessions`)
- core modules (`app.core.config`, `app.core.security`, `app.core.dependencies`)
- schema validation (`app.schemas.auth`, `app.schemas.session`)

Out of scope for now:

- mobile/Flutter tests
- non-functional testing (load/perf/chaos)
- external security pentest tooling

Quality goals:

- consistent API behavior for happy and unhappy paths
- strict auth and ownership boundaries
- robust validation against malformed payloads

## 3. Test architecture

### 3.1 Unit path (`tests/unit`)

Focus:

- password hashing/token validation rules
- environment/config parsing
- dependency auth guard behavior
- schema field constraints and custom validators

Corpus gate:

- `tests/unit/test_analyzer_corpus.py` (the one unit test that takes a few seconds: it scores all fourteen archives once per module) scores the analyzer against the fourteen Slopes archives with the recorded OSM lift lines. It fails when any archive drops more than 0.5 points below `tests/fixtures/slopes/expected_scores.json`, when the corpus falls under the success bar of the GPS segmentation spec, or when it no longer beats the old analyzer's 78.4%. Re-record scores with `python -m app.scripts.evaluate_analyzer --write-expected`; a lower recorded score must be justified in the same commit.

Expected runtime:

- very fast, suitable for every local save loop

### 3.2 QA path (`tests/qa`)

Focus:

- user journeys (register/login/use feature)
- endpoint contracts (status codes + payload shape)
- lifecycle/state transitions (session draft to completed)
- negative cases (conflicts, missing resources, unauthorized access)

Expected runtime:

- still fast enough for pre-commit and PR gates

## 4. Data isolation and reliability model

- QA uses FastAPI `TestClient` with `get_db` override.
- Every test uses a deterministic DB fixture.
- After each QA test, tables are truncated with cascade:
  - `session_points`
  - `ride_sessions`
  - `favorite_resorts`
  - `resorts`
  - `users`
- This keeps tests independent and repeatable across runs.

## 5. Coverage matrix (implemented now)

### 5.1 Unit coverage

- `test_security.py`
  - hash/verify password success and failure
  - malformed hash rejection
  - access/refresh token decode behavior
  - expired token and invalid subject rejection
- `test_config.py`
  - missing DB URL handling
  - token expiry env parsing and invalid values
- `test_schema_validation.py`
  - auth/schema normalization and rejection cases
  - session schema guardrails (ranges, consistency, minimum batch)
- `test_dependencies.py`
  - auth-required behavior
  - token decode failures
  - invalid subject handling
  - unknown-user handling
  - valid path returns resolved user

### 5.2 QA coverage

- `test_system_qa.py`
  - `/` and `/health` smoke checks
- `test_auth_qa.py`
  - register/login/refresh/me/logout flow
  - duplicate email conflict
  - invalid login
  - protected route without token
  - refresh token negative cases (rotated token rejected, reuse revokes the family, logout revokes, malformed and non-ASCII tokens rejected with `Invalid or expired refresh token.`)
  - invalid access-token subject on `/auth/me`
- `test_resorts_favorites_qa.py`
  - resorts list/query/region/detail
  - query/region whitespace normalization behavior
  - pagination checks
  - favorites lifecycle and conflict handling
  - favorites auth-required checks
- `test_sessions_qa.py`
  - create -> points batch -> complete -> list
  - reject points upload after completion
  - reject invalid end time
  - reject missing resort on create
  - sessions auth-required checks
  - cross-user ownership protection
  - reject completing already completed sessions

## 6. Senior QA risk priorities

Highest risk areas to protect at every phase:

- token/auth correctness (`401` handling and guard headers)
- ownership boundaries between users
- session lifecycle transitions and immutability after completion
- payload validation for location/time/speed data

## 7. Execution commands

Run all backend tests:

```bash
python -m pytest
```

Run by path:

```bash
python -m pytest tests/unit
python -m pytest tests/qa
```

## 8. CI quality gates (recommended next step)

Minimum gate for every PR:

- run `tests/unit`
- run `tests/qa`
- block merge on any failure

Recommended add-ons:

- run tests with strict warning handling once flaky warnings are resolved
- track coverage trend (not hard-fail initially)

## 9. Rules for future phases

When adding any new endpoint:

- add at least 1 QA happy-path test
- add at least 1 QA negative-path test
- add unit tests for all non-trivial validation or business logic

When fixing a bug:

- first add a test that reproduces the bug
- then implement the fix
- keep the regression test permanently
