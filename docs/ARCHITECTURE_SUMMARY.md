# GoofyRider Architecture Summary

## System overview

GoofyRider is a mobile + API system with offline-first session recording:

1. Flutter app records location locally first.
2. Drift local store persists sessions and points.
3. Sync worker uploads to backend when network is available.
4. FastAPI persists canonical user/session data in PostgreSQL.
5. Weather data is fetched server-side from Open-Meteo and cached for 60 minutes.

## Mobile layering

`presentation -> domain -> data`

- Presentation:
  - Screens and controllers (`StateNotifier` / Riverpod providers)
- Domain:
  - Entities, state machine, analytics rules, repository contracts
- Data:
  - API clients (Dio)
  - Local database (Drift runtime)
  - geolocator location adapter

Rules enforced:
- Widgets do not call Dio/DB directly.
- Recording logic flows through session repository and analytics engine.

## Backend layering

`api -> services -> repositories -> models`

- API routers:
  - input/output schema validation
  - HTTP code mapping
- Services:
  - business rules
  - ownership checks
  - lifecycle constraints
- Repositories:
  - SQLAlchemy persistence boundaries
- Models:
  - normalized relational schema

Rules enforced:
- No business logic in routers.
- No direct DB access outside repositories.

## Session sync protocol

For locally completed sessions:
1. Create remote draft session if missing `remote_id`.
2. Upload accepted points in batches of 250.
3. Complete remote session with summary stats.
4. Mark local session as `synced`.

Idempotency:
- Backend prevents duplicate `(session_id, t_offset_ms)` points.
- Mobile requests remote points and skips existing offsets before upload.

## Local session state machine

- `idle`
- `recording`
- `paused`
- `locallyCompleted`
- `syncPending`
- `syncing`
- `synced`
- `syncFailed`

Invalid transitions are rejected via `SessionStateMachine`.

## Weather flow

- Client only calls backend weather endpoint.
- Backend weather service:
  - checks cache by resort
  - returns cached data if fresh (<60 min)
  - fetches Open-Meteo when stale/missing
  - persists refreshed snapshot

## Testing strategy

- Backend:
  - unit tests for service and validation logic
  - QA tests for endpoint behavior and lifecycle flows
- Mobile:
  - unit tests for analytics/state machine/sync retry logic
  - widget tests for auth, resorts, history, record state behavior
  - integration test for login -> record -> finish -> sync flow with fakes
