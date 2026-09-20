# Fall Line project audit (2026-09-12)

Read-only audit of the whole repository: architecture, layout, implementation,
tests, external providers, GPS pipeline, and security. No application code was
changed. Every number below was produced by running the tools on this machine
on 2026-09-12 against commit `205503b` on `main`.

Companion documents:

- `docs/FEATURE_RESEARCH.md` — features users of ski/snowboard trackers ask for
  that Fall Line does not have yet (research only).
- Sub-project specs for security hardening and GPS segmentation will be written
  separately under `docs/superpowers/specs/` and reference this audit.

---

## 1. Verdict in one screen

The architecture is sound and the layering rules in `CLAUDE.md` are followed
almost everywhere. The main problem is not design quality; it is that the
repository is frozen halfway through a migration. The backend was rewritten to
own session analysis (`SessionAnalyzer`, actions, overrides, `/detail`) while
the mobile app still runs its own pipeline and still reads and writes the old
session contract. Nothing has reconciled the two, and both CI gates are red.

| Check | Result | Consequence |
|---|---|---|
| Backend `pytest` (196 tests, dedicated test DB) | **pass** | Business logic works |
| Backend `ruff check` | **16 errors** (15 auto-fixable) | CI backend job fails at lint |
| Backend `ruff format --check` | **16 files** would be reformatted | CI backend job fails at lint |
| Backend `mypy --strict` | **12 errors** in 5 files | CI backend job fails at type-check |
| Mobile `flutter analyze` | **261 issues** (all `info`, mostly deprecation) | CI mobile job fails (infos are fatal by default) |
| Mobile `flutter test` | **200 pass, 17 fail** | CI mobile job fails |
| Mobile `integration_test` | not run (needs a device, uses fakes) | No true end-to-end coverage |

Two of the mypy errors are real runtime bugs (section 3, C1 and C2).

---

## 2. Architecture and layout

### 2.1 What is right

- Backend layering `api -> services -> repositories -> models` is respected.
  Routers bind input and call one service method. Services raise
  `ServiceError` subclasses and never touch `HTTPException`. Repositories are
  the only SQLAlchemy consumers, with one exception noted in C1.
- Mobile layering `presentation -> domain -> data` is respected. Widgets do not
  call Dio or Drift. Persistence goes through DAOs. Session lifecycle goes
  through `SessionStateMachine`.
- Config, migrations, and idempotent write paths follow the documented patterns
  (uniqueness constraint + service dedup + one retry on `IntegrityError`).
- The native Android location bridge is well done: monotonic-clock ordering,
  stale-sample rejection, a native watchdog, and a foreground service with the
  correct `foregroundServiceType`.
- Test volume is healthy for a solo project: 196 backend tests split into unit
  and QA, 217 mobile tests split into unit and widget, plus a stats-replay
  parity test that checks live and post-hoc segmentation agree.

### 2.2 The half-finished migration

`plans/slopes_parity_rebuild_plan.md` (Steps 0 to 12) moves session analysis
to the backend. Steps 0 through 6 are in the code; Step 7 is partially there
(the importer parses archives but writes a schema that no longer exists);
Steps 8 through 12 are not started. The visible effects:

| Area | Backend today | Mobile today |
|---|---|---|
| Session summary contract | `descent_*`, `lift_*`, `total_duration_s`, `avg_descent_speed_mps`, actions and overrides | still reads `duration_s`, `distance_m`, `avg_speed_mps`, `elevation_gain_m`, `elevation_loss_m` |
| `/sessions/{id}/complete` payload | `{ended_at}` only | still sends 7 summary fields (silently ignored) |
| Point enrichment (`motion_state`, `quality_class`, `filtered_*`, `distance_delta_m`) | dropped in migration 0011 | still stored locally, still sent, still expected back from `/points` |
| Classification | `SessionAnalyzer` (backend truth per plan) | six-stage live pipeline plus `session_segmentation.dart`, never calls `/detail` or `/analyze` |
| Thresholds | descent 2.0 m/s, lift cap 10.0 m/s | descent 4.0 m/s, lift cap 8.0 m/s |
| Lift catalog (`resort_lifts`) | table, model, repository, tests | never populated, never injected into the analyzer |

The old `CLAUDE.md` rule "SessionPoint enriched fields are part of the
backend/mobile contract" was therefore already violated by the backend, and an
agent following it would protect a contract that no longer exists. Section 9
records the rewording applied on 2026-09-12.

### 2.3 Documentation drift

| Document | State |
|---|---|
| `FINDINGS.md` | dated 2026-04-12; predates ruff, mypy, the analyzer, actions, overrides, and the Fall Line redesign; now marked historical in `CLAUDE.md` |
| `docs/ARCHITECTURE_SUMMARY.md` | describes the old "complete with summary stats" protocol |
| `backend/tests/TEST_PLAN.md` | "Phase 1-3 baseline", no analyzer or override coverage matrix |
| `plans/IMPROVEMENTS_PLAN.md` | items #1 and #2 (ruff, mypy) landed; #4 (split SessionPoint) was superseded by the rebuild |
| `plans/gps_location_stack_overhaul_plan.md` | Steps 1 to 6 landed; Step 7 (battery allowlist) and the 5b auto-resume are not |
| `README.md` | still GoofyRider naming; instructs bundling real keys for reviewers |
| `CLAUDE.md`, `FINDINGS.md`, `plans/` | live one directory above the git root (`goofy-rider/`) and are not version-controlled |

---

## 3. Findings by severity

Severity: **C** = broken or will break at runtime, **H** = CI red or user-visible
wrong data, **M** = quality debt worth paying, **L** = cosmetic.

### Critical

**C1. Slopes importer writes columns that no longer exist.**
`backend/app/services/slopes_import_service.py` (`import_directory` around
lines 295-305 and `_repair_existing_session` around 299-309) builds
`RideSession(duration_s=..., distance_m=..., avg_speed_mps=...,
elevation_gain_m=..., elevation_loss_m=...)`. Those columns were dropped by
migration 0011. Running `python -m app.scripts.import_slopes_sessions` raises
`TypeError` on the first file. Unit tests pass because they only cover
parsing. The same file also queries SQLAlchemy directly from a service, which
breaks the repository rule. Plan Step 7 ("Slopes importer rewrite") is the fix;
until then the script should be marked broken or removed.

**C2. Dead backfill script targets a dropped table.**
`backend/app/scripts/backfill_session_point_analytics.py` inserts into
`session_point_analytics`, dropped in 0011. It would fail on first execution.
Delete it.

> **2026-09-20 update:** C2 is fixed. The script was deleted; nothing imported
> it and it had no test coverage.

**C3. Backend boot depends on a third-party API.**
`docker-compose.yml` starts the backend with
`alembic upgrade head && python -m app.scripts.import_resorts && uvicorn ...`.
`import_resorts.main()` raises `SystemExit` on any SkiAPI error, so a missing
key, a rate-limit response, or a SkiAPI outage prevents uvicorn from starting.
The scheduler already syncs periodically; boot should not block on it.

> **2026-09-19 update:** C3 is fixed. The boot command no longer imports
> resorts and the in-process scheduler is removed; the catalog is loaded by
> `python -m app.scripts.import_catalog`. The section 5.1 recommendation is
> adopted: OpenSkiData is the primary catalog and lift source, SkiAPI is
> Phase 2 enrichment. See
> `docs/superpowers/specs/2026-09-19-resort-catalog-design.md`.

### High

**H1. Backend lint and type gates are red on `main`.**
ruff: unsorted imports in `models/__init__.py` and `slopes_import_service.py`,
quoted annotations under `from __future__ import annotations` (UP037) in four
model files, unsorted `__all__` twice, an ambiguous multiplication sign in a
comment (`session_analyzer.py:102`), `typing.Iterable` instead of
`collections.abc.Iterable`. mypy: `_build_action_record` calls `max()` over
`float | None` (runtime-safe because the list is pre-filtered, but the type
does not say so), `SessionPointInput` is re-exported from
`schemas/session.py` without `__all__`, and the two runtime bugs above.

**H2. Mobile test suite has 17 failures.**
- 13 fail with `SqliteException: no such table` in
  `drift_local_database_integrity_test.dart` (9),
  `session_resort_attribution_service_test.dart` (3), and
  `debug_export_service_test.dart` (1). Reproduced in isolation
  (`flutter test test/unit/debug_export_service_test.dart` fails alone with
  the same exception from `SessionDao.insertLocalSession`). Both open paths
  fail: tests using `DriftLocalDatabase.openInMemory()` (which calls
  `initialize()`) and tests using `connectForTesting()` (which does not).
  Root cause, confirmed against the drift 2.32.0 source
  (`lib/src/runtime/executor/helpers/engines.dart`, `_runMigrations`):
  drift reads `user_version`, runs `beforeOpen` (which creates nothing here
  because `allTables` is empty), and then calls `setSchemaVersion(4)`, all
  inside the open that is triggered by the first statement `initialize()`
  issues, which is `PRAGMA user_version`. That query therefore returns 4,
  `initialize()` sees `currentVersion >= schemaVersion` and returns before
  any `CREATE TABLE` runs. The 41 passing `session_repository_impl_test.dart`
  tests do not use either open path, which is why they are unaffected. Fix:
  key the guard on a table-existence check or on a separate stored version,
  not on drift's `user_version`, or move schema creation into drift's
  `MigrationStrategy.onCreate`.
- 3 fail in `profile_screen_test.dart` because the "Export debug info" and
  "Clear local cache" tiles are commented out in `profile_screen.dart`.
- 1 fails in `history_screen_test.dart`
  ("keeps sync state visible and no per-card overflow actions") because the
  redesigned card no longer renders the widget the test looks for.

**H3. Mobile analyzer is red on `main`.**
`flutter analyze` reports 261 infos. Almost all are
`deprecated_member_use_from_same_package`: `DriftLocalDatabase` still exposes
about 40 `@Deprecated` forwarding stubs and every production caller still uses
them. The DAO refactor was started but never completed. Either migrate callers
to `db.sessions.*`, `db.sessionPoints.*`, and so on and delete the stubs, or
remove the deprecation annotations. Leaving it half-done fails CI.

**H4. Remote-only sessions show zero stats.**
`session_repository_impl.dart` `_hydrateRemoteSessionSummaries` and
`_mapRemoteAsLocal` read `duration_s`, `distance_m`, `avg_speed_mps`,
`elevation_gain_m`, `elevation_loss_m` from `/users/me/sessions`. None exist
in `SessionSummary` any more, so any session that only exists on the server
(after a reinstall, or a second device) renders as 0:00:00, 0 m, 0 km/h.
Home, history, season summary, and profile all inherit the zeros.

**H5. Remote point restore re-downloads on every detail open.**
`_shouldRefreshRemotePoints` returns true when points lack `motion_state` and
`distance_delta_m`. The backend no longer stores either, so a restored session
never satisfies the check and `getSessionDetail` fetches all points from the
server every time the screen opens, then replays the whole pipeline.

**H6. Widget tests perform real network I/O.**
`session_detail_screen_test.dart` and `record_screen_test.dart` render
`FlutterMap` with the OSM dev fallback and the test log fills with
`ClientException: Request to https://tile.openstreetmap.org/... failed`. This
makes tests slow, environment-dependent, and hits the OSM tile servers from
automated runs, which their usage policy forbids. Inject a no-op tile provider
in tests.

### Medium (backend)

**M1. Unused repositories and protocol methods.**
`SessionActionRepository` and `ResortLiftRepository` (and their protocols) are
only used by their own unit tests. `ResortRepositoryProtocol.count_filtered`
and `list_filtered`, and `RideSessionRepositoryProtocol.count_by_user` and
`list_by_user`, are superseded by the `_with_count` variants.
`SessionService.get_session` has no caller.
`SessionPointPublic.from_session_point` is a one-line wrapper around
`model_validate`.

**M2. Duplicate definitions.**
`SessionCondition` enum exists in both `models/ride_session.py` and
`schemas/session.py`. Haversine is implemented in `session_analyzer.py` and
again in `slopes_import_service.py`. `_parse_session_completion_payload` and
`_parse_session_analyze_payload` in `api/sessions.py` are the same function
with a different model and message; they also re-implement the 422 mapping
FastAPI performs by default, only to change the error envelope shape.

**M3. Redundant eager loading.**
`RideSession.resort` is declared `lazy="joined"` and every query also adds
`joinedload(RideSession.resort)`. Pick one.

**M4. Async and sync are mixed.**
`health_check` and `root` are `async def`; everything else is sync. Harmless,
but `IMPROVEMENTS_PLAN.md` #7 already flags the inconsistency.

**M5. Personal data in logs.**
`auth_service.py:57` and `:63` log the email address on register and on every
failed login. Log the user id, or nothing, for failures.

**M6. Test fixtures list wrong tables.**
`tests/unit/repositories/conftest.py` truncates `ride_session_points`, which
does not exist; `tests/qa/conftest.py` omits `ride_session_actions`,
`ride_session_overrides`, and `resort_lifts` (cascade currently hides this).

**M7. Provider clients are created per call.**
`OpenMeteoWeatherProvider.fetch` and `SkiApiResortSource._fetch_page` build a
fresh `httpx.Client` per request when none is injected. Fine at this scale;
a module-level client would reuse connections.

### Medium (mobile)

**M8. God objects.**
`session_repository_impl.dart` is 1,932 lines and mixes upload batching,
payload sanitization (about 600 lines), remote-delete reconciliation, history
merging, stats computation, and remote point restore.
`recording_controller.dart` is 1,529 lines even after extracting five helper
managers. Splitting the repository into an uploader, a delete reconciler, and
a stats calculator would make the Step 9/10 contract change tractable.

**M9. Duplicated pipeline logic.**
`_assessPlatformSpeedTrust`, `_isGeometrySpeedReliableForCoherence`, and
`_horizontalAcceptThresholdForSample` are copied between
`quality_classifier.dart` and `speed_fusion.dart` (acknowledged in a
comment). The fall rule is implemented in
`MotionStateDetector._stoppedIdleBucket` and again in
`session_segmentation._FallRuleState`. `haversineDistanceMeters` lives in
`session_models.dart`. All of this disappears if the backend becomes the
classifier, which argues for finishing the rebuild rather than refactoring
here.

**M10. Copy-paste preference controllers, and secrets storage used for
non-secrets.**
`distance_unit_preference_provider.dart` and
`speed_unit_preference_provider.dart` are identical apart from the enum. Both,
plus `GpsWarmupPermissionPreference`, persist ordinary preferences in
`flutter_secure_storage`, which is Keystore-backed, slower, and known to throw
on some OEM ROMs (hence the `PlatformException` catches). Use
`shared_preferences` for preferences and keep secure storage for tokens.

**M11. Layering slips.**
`debug_export_service.dart` sits in `profile/presentation/` but reads Drift
directly; it belongs in `data/`. `auth_providers.dart` constructs `Dio`
inside `presentation/`; providers are wiring, but a `providers.dart` at the
feature root keeps `presentation/` free of transport code.
`native_android_tracking_repository.dart` uses `debugPrint` three times
instead of `AppLogger`.

**M12. Dead and commented-out code (usage verified by grep).**
- `profile_screen.dart` carries about 90 commented-out lines (cache clear,
  debug export). `DebugExportService` and `debugExportActionProvider` are now
  unreachable from the UI.
- `core/utils/enum_serialization.dart`: `enumToWire`, `enumFromWire`,
  `buildReverseWireMap` have zero references.
- DAO methods with zero production callers: `SessionDao.getSessionByLocalId`,
  `SessionDao.incrementSyncAttempt`, `SessionDao.updateSessionResortId`,
  `PendingDeleteDao.listPendingRemoteDeleteIds` (superseded by
  `listRetryablePendingRemoteDeletes`).
- `LocalSessionState.locallyCompleted` is kept only for rows that
  `_normalizeLegacySessionStates` already rewrites on every start.
- `TrackingModeProfiles` defines two profiles that differ only in watchdog
  timeout; `TrackingModePriority.balancedPower` is never selected;
  `waitForAccurate` and `maxDelayMs` are constants.

**M13. Brittle error classification.**
`_isLikelyValidationFailure` matches error text for `'ge=0'` and
`'input should'`. The backend returns structured 400/422; branch on status.

**M14. Silent failures.**
Sixteen `catch (_) {}` sites in `lib/`, including `_recordTrackingDiagnostic`
and the map `move` calls. `AppLogger` is a no-op in release builds, so a
release build has zero diagnostics and no crash reporting. Together these
hide exactly the field failures the GPS work needs to see.

**M15. Raw UUID on the home screen.**
`_LastSessionCard` renders `session.resortId ?? 'Unknown resort'`; history
resolves the label, home does not.

**M16. Formatting drift.**
Redesign screens contain 200+ character one-line widget trees. `dart format`
is not enforced in CI; add `dart format --set-exit-if-changed`.

**M17. Timeline cache key.**
`session_segmentation._timelineCache` is keyed on `(localSessionId,
pointCount)`. Replacing points with the same count (remote restore) returns a
stale analysis. It is also process-global mutable state.

**M18. Inconsistent identifiers.**
`userAgentPackageName: 'com.goofyrider.mobile'` in two screens while
`applicationId` is `com.example.goofyrider_mobile`.

### Low

- `Dockerfile` has no `HEALTHCHECK`; `docker-compose.yml` exposes Postgres on
  the host (fine locally, remove when hosted).
- CLI scripts use `print`; acceptable for a CLI, but `CLAUDE.md` says logging.
- Foreground notification uses `R.mipmap.ic_launcher` as the small icon;
  adaptive icons render as a flat square there. Provide a monochrome drawable.
- `gradle.properties` requests 8 GB heap.
- `TEST_PLAN.md` and `ARCHITECTURE_SUMMARY.md` need a refresh after the
  rebuild lands.

---

## 4. Test coverage assessment

| Layer | Backend | Mobile |
|---|---|---|
| Unit | 148 tests: analyzer (14), session service (21), config (21), security (7), schemas (8), importers, scheduler | 173 tests: pipeline (20), segmentation (13), repository impl (41), controller resilience (14), native bridge (11), warm-up (9), state machine (4), parity (2) |
| Integration / QA | 55 API tests through `TestClient` against a real Postgres: auth (8), sessions (15), analyze and override (22), resorts and favorites (5), weather (2), system (2) | 42 widget tests (screens, tab bar, design widgets); 1 device integration test with fake auth and fake location |
| End-to-end | none | none (the integration test never talks to the backend) |

Gaps that matter:

1. **No contract test between the two apps.** Nothing would have caught H4.
   A backend QA test that snapshots `SessionSummary` JSON, checked into the
   mobile repo as a fixture for `session_repository_impl_test.dart`, closes
   the gap cheaply.
2. **Analyzer has no fixture-based regression corpus.** Fourteen real Slopes
   archives sit in `slopes-files/` and three in
   `backend/tests/fixtures/slopes/`, but only the parser is tested against
   them. Running `SessionAnalyzer` over the fixture GPS and asserting run and
   lift counts within a tolerance of the Slopes actions is the single most
   valuable test for the GPS sub-project.
3. **Mobile tests hit the network** (H6).
4. **Migration tests are broken** (H2), which is the one place a schema bug
   would be caught before it corrupts a user's local database.
5. No test covers `ResortSyncScheduler` failure at boot (C3).

---

## 5. External providers

### 5.1 SkiAPI (RapidAPI) for the resort catalog

- What it gives: resort name, country, region, city, coordinates, base and
  top elevation, paged, free tier rate-limited.
- What it does not give: lift and run geometry, which the analyzer already
  supports and the GPS work needs.
- Risks: boot coupling (C3); free tier limits; RapidAPI key in `.env`.

**Better free option: OpenSkiMap / OpenSkiData.** The
[openskidata-processor](https://github.com/russellporter/openskidata-processor)
turns OpenStreetMap `piste:*` and `aerialway=*` data into GeoJSON and a
GeoPackage with three layers: ski areas, runs, and lifts, including names,
difficulty, and lift type. It is the same data behind
[OpenSkiMap.org](https://openskimap.org/). This gives you the resort catalog,
the `resort_lifts` polylines, and run names in one import, at no cost, under
ODbL attribution. Recommendation: import an OpenSkiData snapshot as the
primary catalog, keep SkiAPI as an optional enrichment, and move the import
out of the boot command.

> Adopted 2026-09-19; see the note under C3.

Paid options that add live lift status and official snow reports:
[Mountain News / OnTheSnow partner API](https://www.mountainnews.com/data-ai/)
(2,000+ resorts, lift and trail status, 10 years of snowfall history) and
[WeatherUnlocked Ski Resort API](https://developer.weatherunlocked.com/skiresort)
(3,000 ski areas). Neither is needed until you want live lift status.

### 5.2 Open-Meteo for weather

- Free for non-commercial use, no key. The integration is correct and cached.
- Two easy accuracy wins you are not using: the `elevation` query parameter
  (without it the forecast is for the grid-cell mean height, not the summit;
  pass `elevation_top_m` or call twice for base and top) and the hourly
  `snow_depth` and `freezing_level_height` variables
  ([docs](https://open-meteo.com/en/docs)). Daily `snowfall_sum` is already
  used.
- Open-Meteo itself notes mountain forecasts are less accurate without
  elevation downscaling.

Paid options: WeatherUnlocked (base, mid, and top forecasts updated four times
daily), [OpenSnow API](https://opensnow.com/api/start) (elevation-specific,
their PEAKS model claims large accuracy gains in terrain), The Weather Company
snow and ski conditions. Recommendation: stay on Open-Meteo, add `elevation`
and `snow_depth` now, revisit WeatherUnlocked only if you want official resort
snow reports.

### 5.3 Mapbox raster tiles

- Correctly centralized in `MapTileProviderConfig`. Raster Styles tiles are
  billed per tile request beyond a monthly free allowance; a public token in
  an APK cannot be URL-restricted, so watch usage alerts and rotate the token.
- Neither Mapbox Outdoors nor the OSM fallback draws pistes and lifts
  prominently, which is the one thing a ski map needs.

**Better fit:** [MapTiler](https://www.maptiler.com/news/2022/03/maps-for-winter-sports-apps/)
ships a Winter style with pistes and lifts and works with the same
`flutter_map` URL-template mechanism, so it is a config-level swap with a
free tier. The stronger long-term option is MapLibre vector tiles with an
OpenSkiMap runs-and-lifts overlay, which also lets you highlight the run you
just skied. Both keep `MapTileProviderConfig` as the single switch.

### 5.4 Location: Fused Location Provider via native bridge

- The right choice on Android. The bridge asks for `PRIORITY_HIGH_ACCURACY`
  at 1 Hz with no distance filter, which is correct for sport tracking.
- Not yet used: the barometric pressure sensor (vertical rate is the best lift
  versus run discriminator and phones have it), and the Activity Recognition
  transition API (free `STILL` / `IN_VEHICLE` / `ON_FOOT` signals that
  separate a chairlift from walking to the lodge). Both are inputs to the GPS
  sub-project, not provider swaps.
- `geolocator` remains as a fallback and for the warm-up stream. Fine.

---

## 6. GPS and segmentation: observations for sub-project 4

These are inputs for the design, not a design.

1. **Two classifiers with different thresholds** (section 2.2). Decision
   already taken: the backend analyzer becomes the truth. Mobile keeps only
   what the live HUD needs (speed, altitude, elapsed, a coarse state for the
   UI).
2. **The backend analyzer is currently weaker than the mobile pipeline.** It
   filters on horizontal accuracy alone (no jump, spike, or monotonic-time
   gate), classifies per sample from a raw altitude delta (no altitude
   smoothing, no hysteresis, no heading stability), and relies on
   `_absorb_mid_action_ignores` to paper over flicker. A single 6-minute
   stop between two descents inside `MAX_MID_ACTION_IGNORE_S` is counted as
   descent time, which is exactly the "short stop versus real break" question
   you raised.
3. **The lift catalog is the biggest single lever.** Matching a track to an
   `aerialway` polyline by distance and bearing alignment is close to
   deterministic for lifts, which then makes runs "everything descending
   between lifts". OpenSkiData supplies the geometry (section 5.1).
4. **Stop taxonomy.** A useful model has four states: descent, lift, short
   stop (in-run fall or rest: under about 90 s, drift under 15 m, previous
   state descent), and long stop or walk (lift line, lodge, traverse on foot:
   dwell over a few minutes, or displacement at walking speed, or proximity
   to a lift base or `amenity=restaurant` node). A small Viterbi or HMM over
   per-second features (smoothed speed, vertical rate, heading consistency,
   accuracy, distance-to-lift-line) with duration priors handles this far
   better than threshold cascades and is easy to evaluate against the
   fourteen Slopes archives, which carry Slopes' own run and lift actions as
   labels.
5. **Vertical signal.** GPS altitude is the noisiest input you have. A
   barometer-fused altitude (native side) or at least a proper altitude
   smoother with `vertical_accuracy_m` weighting on the backend would sharpen
   both lift detection and vertical totals.
6. **Speed.** Top speed from raw platform speed with the 2x spike ratio is
   reasonable. Use `speed_accuracy_mps` (already stored) to weight or reject
   samples instead of ignoring it.

---

## 7. Security: observations for sub-project 3

Scope agreed: local-only hosting for now, but harden from the ground up.

| # | Finding | Where | Recommendation |
|---|---|---|---|
| S1 | Refresh tokens are never rotated or revoked; `/auth/logout` is a no-op; a stolen refresh token works for 14 days and refreshing does not invalidate the previous one | `auth_service.py`, `api/auth.py` | Store refresh token `jti` per user with revocation; rotate on every refresh; reuse of a rotated token revokes the family; make logout revoke |
| S2 | PBKDF2-SHA256 at 390,000 iterations is below the 2026 OWASP floor of 600,000 and is not memory-hard | `core/security.py` | Argon2id (`argon2-cffi`), keep PBKDF2 verify for existing hashes and re-hash on login |
| S3 | No rate limiting on login, register, refresh | `api/auth.py` | `slowapi` or a small in-process limiter keyed by IP and email; add a per-user cap on point uploads |
| S4 | Login timing side channel: `verify_password` only runs when the user exists | `auth_service.login` | Always run a dummy verification |
| S5 | `/docs`, `/redoc`, `/openapi.json` always on | `main.py` | Disable outside a `debug` setting |
| S6 | JWT carries only `sub`, `type`, `iat`, `exp`; no `iss`, `aud`, `jti` | `core/security.py` | Add all three; `jti` is required for S1 |
| S7 | Emails in logs | `auth_service.py` | Log user id only |
| S8 | README instructs shipping real `.env` and `mapbox.json` to reviewers; both files are correctly untracked and were never committed (verified with `git log --all`) | `README.md` | Ship `.example` files only; rotate the Mapbox token and SkiAPI key once before sharing the app |
| S9 | No `network_security_config.xml`; cleartext HTTP is used for the emulator base URL | `AndroidManifest.xml` | Allow cleartext only in a debug build variant; release must be HTTPS-only |
| S10 | Release signed with the debug keystore; `applicationId` is `com.example.*`; no `minifyEnabled`, `shrinkResources`, or obfuscation configuration anywhere in the Android project (verified) | `build.gradle.kts` | Real upload keystore outside git; new application id; `flutter build --obfuscate --split-debug-info`; explicit R8 configuration |
| S11 | `allowBackup` is not set (defaults to true), so the local SQLite and Keystore-backed prefs can land in device backups | `AndroidManifest.xml` | `android:allowBackup="false"` or a backup rules file excluding the DB |
| S12 | `is_mocked` is stored but never acted on | analyzer, session service | Flag sessions with mocked points; matters once there are leaderboards |
| S13 | Postgres published on the host, backend port open | `docker-compose.yml` | Remove `ports` on `db`; put a reverse proxy in front when hosting |
| S14 | No security headers, no HTTPS termination | hosting | Deferred until a host is chosen; the design will be in the spec |

Good things already in place: Bearer auth on every data route with ownership
checks, LIKE-wildcard escaping in resort search, bounded pagination and batch
sizes, tokens in `flutter_secure_storage`, non-root container user, the
test-database name guard, and Pydantic bounds on every numeric field.

---

## 8. Dependencies worth pinning

- `play-services-location:21.2.0` is pinned; fine.
- Backend `pyproject.toml` has no lock file. `pip check` in CI is not a lock.
  A `requirements.lock` (or `uv lock`) makes the Docker image reproducible.
- Mobile uses `pubspec.lock` with `--enforce-lockfile` in CI; good.

---

## 9. `CLAUDE.md` changes (approved and applied 2026-09-12)

1. **Name the active migration and the direction of truth.** The backend
   `SessionAnalyzer` is the source of truth for run, lift, and stop
   classification; the mobile pipeline is transitional per
   `plans/slopes_parity_rebuild_plan.md` Steps 8 to 12; do not add
   classification rules to the mobile pipeline.
2. **Replace the stale SessionPoint contract rule.** Raw fixes go up
   (`SessionPointInput`), analysis comes down (`SessionDetailResponse` with
   actions and overrides); any change requires the backend schema, the mobile
   API client, and the Drift schema to change together, with a shared JSON
   fixture test.
3. **Demote `FINDINGS.md`** to historical context, and add this audit as the
   current-state source.
4. **Add the quality gates as rules.** `ruff check`, `ruff format --check`,
   `mypy`, `flutter analyze`, `flutter test` must pass before a change is
   called done; tests must not perform network I/O; `dart format` is enforced.
5. **Small mobile additions.** Providers and DI wiring live in a feature-root
   `providers.dart`, not under `presentation/`; `debugPrint` is banned in
   favour of `AppLogger`; ordinary preferences use `shared_preferences`,
   secure storage is for credentials only.

Note: `CLAUDE.md` sits in `goofy-rider/`, one level above the git root, so
these edits are not tracked by git. Consider moving it (and `plans/`) inside
the repository.

---

## 10. Suggested order for the cleanup sub-project

1. Make CI green: `ruff --fix`, `ruff format`, the mypy fixes, delete C2,
   fix or quarantine C1, repair the 13 database tests, delete or restore the
   profile debug tiles and their tests, stub tiles in widget tests.
2. Decouple boot from SkiAPI (C3).
3. Finish the DAO migration (H3) or drop the deprecations.
4. Fix the remote session mapping (H4, H5) as the first slice of rebuild
   Steps 9 and 10, guarded by the shared fixture test from section 4.
5. Remove the dead code in M1, M2, M12; move `debug_export_service` to
   `data/`; replace `debugPrint`.
6. Add the analyzer regression corpus over the Slopes fixtures before the GPS
   sub-project starts, so every threshold change is measured.
