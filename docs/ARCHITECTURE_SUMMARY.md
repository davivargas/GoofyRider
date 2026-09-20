# Fall Line Architecture Summary

## System overview

Fall Line is a mobile + API system with offline-first session recording:

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

Session run/lift/stop classification and per-session statistics live in the
`app/services/analysis/` package (`config.py`, `signal.py`, `lift_matching.py`,
`hmm.py`, `actions.py`, `analyzer.py`, plus `geo.py` and `types.py` for shared
helpers and dataclasses). `app/services/session_analyzer.py` is a
compatibility shim that re-exports the package's public API so existing
imports keep working; new code should import from `app.services.analysis`
directly.

## Resort catalog

- Sources write only `resort_source_records` (raw payload, sha256 hash,
  snapshot build time, `missing_since`, link to a resort with
  `match_status` / `match_method` / candidates). OpenSkiData is the only
  source. The legacy `ski_api` records written by migration 0016 (for resorts
  that predate the multi-source catalog) are still read for merge purposes via
  `legacy_resort_mapping.py`; nothing writes new `ski_api` records.
- `resort_matching.py` (pure) scores name similarity, distance or boundary
  containment, and country agreement; auto-links at ≥ 0.85 with a 0.15 margin
  and ≤ 5 km, queues ≥ 0.5 for review, never orphans a legacy row.
- `resort_merge_service.py` recomputes every `resorts` column from linked
  records plus `resort_field_overrides` using a fixed precedence
  (OpenSkiData, then legacy `ski_api`) and plausibility checks (elevations
  within the lift envelope ±150 m, coordinates inside the boundary). Provenance per field
  lives in `resorts.field_provenance`. Recency is never a rule.
- Lifts come from the OpenSkiData `lifts.geojson` into `resort_lifts`
  (`source = openskidata`, track id `osm:way:<id>`), replacing the per-resort
  Overpass fetch. The analyzer contract (`polyline` JSON, `external_track_id`)
  is unchanged.
- Commands: `app/scripts/import_catalog.py` (explicit, idempotent, no boot
  coupling) and `app/scripts/review_catalog_matches.py`.
- Geometry is JSONB plus a bbox in plain Postgres; the column shape allows a
  later PostGIS migration in one revision.

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
