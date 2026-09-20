# Multi-source resort catalog design

Date: 2026-09-19
Status: approved in brainstorming, awaiting implementation plan
Scope: backend catalog import (OpenSkiData primary, SkiAPI enrichment), lift
storage, matching, merge, review workflow, mobile attribution.

## 1. Goal

Combine OpenSkiData (OpenStreetMap ski data behind openskimap.org, produced by
`russellporter/openskidata-processor`) and SkiAPI (RapidAPI "Ski Resorts and
Conditions") into one resort catalog with one merged row per resort,
per-field provenance, deterministic conflict resolution, and a review list for
uncertain matches. The mobile contract (`GET /v1/resorts`,
`GET /v1/resorts/{id}`, `ResortPublic`) does not change.

Phase 1 (OpenSkiData primary, lifts, matching, merge, commands) ships on its
own. Phase 2 adds SkiAPI as an enrichment source using the same machinery.
Runs (piste geometry) are out of scope for both phases.

## 2. Verified facts the design relies on

### 2.1 Repository state (verified 2026-09-19 against code)

- `resorts` has `name`, `country`, `region`, `city`, `latitude`, `longitude`,
  `elevation_base_m`, `elevation_top_m`, one `external_source` /
  `external_id` pair, `last_source_sync_at`, `is_active`. Unique constraints:
  (name, country, region) and (external_source, external_id).
- `resort_lifts` already exists (migration 0011): `name`, `lift_type`
  (check: chair, gondola, surface, tbar, magic_carpet), `osm_aerialway`,
  `polyline` as JSON text `[[lat, lon], ...]`, `base_altitude_m`,
  `top_altitude_m`, `external_track_id` (`osm:way:<id>`). It is filled per
  resort by `OsmLiftCatalogService` through the public Overpass API and the
  `import_resort_lifts` script. `SessionService._load_resort_lifts` converts
  rows to the analyzer's `ResortLift` dataclass; `lift_matching.anchor` uses
  `polyline`, `name`, `lift_type`, `osm_aerialway`, `external_track_id`.
- `ResortImportService` imports from SkiAPI only and writes straight to
  `resorts`. `docker-compose.yml` runs the import at boot (audit defect C3),
  and `ResortSyncScheduler` repeats it weekly inside the API process.
- Postgres image is `postgres:15`, no PostGIS.
- Backend deps: FastAPI, SQLAlchemy 2, Alembic, psycopg, pydantic 2, httpx.
  Tooling: ruff, mypy strict, pytest. Alembic head is `0015`; `0005` is
  intentionally absent.
- `goofyrider/` is the git root. Existing dev databases hold SkiAPI-sourced
  resorts referenced by sessions, favourites, and `resort_lifts` (Grouse,
  Cypress, Seymour).

### 2.2 OpenSkiData

Verified from openskidata.org, tiles.openskimap.org/metadata.json and the
`openskidata-format` repository on 2026-09-19.

- Downloads (rebuilt daily):
  - `https://tiles.openskimap.org/metadata.json` (build time, OSM data
    timestamp, per-dataset feature counts and uncompressed sizes)
  - `https://tiles.openskimap.org/geojson/ski_areas.geojson`
  - `https://tiles.openskimap.org/geojson/lifts.geojson`
  - `https://tiles.openskimap.org/geojson/runs.geojson` (not used)
  - `https://tiles.openskimap.org/geojson/spots.geojson` (not used)
  - CSV variants and `https://tiles.openskimap.org/openskidata.gpkg` (not used)
- Sizes on 2026-09-18: ski areas 12,244 features / 20.7 MB GeoJSON; lifts
  33,201 / 116 MB; runs 229,646 / 844 MB; GeoPackage 409 MB.
- Ski area feature: geometry `Point | Polygon | MultiPolygon`; properties
  `id`, `name | null`, `activities` (`downhill`, `nordic`), `status | null`
  (`operating`, `disused`, `abandoned`, `proposed`, `planned`,
  `construction`), `sources[]` (`{type: "openstreetmap" | "skimap.org",
  id}`), `statistics?` (`runs`, `lifts`, `minElevation?`, `maxElevation?`,
  each of `runs` and `lifts` also carrying `minElevation?` /
  `maxElevation?`), `runConvention`, `websites[]`, `wikidataID | null`,
  `places[]` (`{iso3166_1Alpha2, iso3166_2 | null, localized: {en:
  {country, region | null, locality | null}}}`), `viewportHint`.
- Lift feature: geometry `LineString | MultiLineString` with 3D coordinates
  (`[lon, lat, ele]`); properties `id`, `liftType` (`cable_car`, `gondola`,
  `chair_lift`, `mixed_lift`, `drag_lift`, `t-bar`, `j-bar`, `platter`,
  `rope_tow`, `magic_carpet`, `funicular`, `railway`), `status`, `name |
  null`, `ref`, `oneway`, `occupancy`, `capacity`, `duration`, `detachable`,
  `bubble`, `heating`, `stations[]`, `skiAreas[]` (summary features with
  `id`, `name`), `sources[]`, `places[]`.
- Elevations are provided (terrain-derived), not something we must compute.
- Licence: free to use including commercially, with the attribution
  "Data from OpenSkiData / OpenSkiMap.org, © OpenStreetMap contributors
  (ODbL), Skimap.org, Who's On First, © Mapterhorn".

### 2.3 SkiAPI

- `GET {base_url}/resort?page&per_page` returns `{data: [{slug, name,
  country, region, location: {latitude, longitude}, url}], next_page}`
  (see `tests/fixtures/ski_api_resorts_page.json`). The detail endpoint
  `GET {base_url}/resort/{slug}` carries elevation and conditions.
- Headers `X-RapidAPI-Key` and `X-RapidAPI-Host`. The RapidAPI host is
  `ski-resorts-and-conditions.p.rapidapi.com`. The correct base URL is still
  being confirmed by the user from the RapidAPI code snippet; nothing in this
  work calls the live API, and the config default is not changed until the
  URL is confirmed.

## 3. Decisions taken in brainstorming

| Topic | Decision |
|---|---|
| Runs | Not imported. Lifts only in Phase 1. Runs are a later phase with their own consumer. |
| Field precedence | OpenSkiData primary for every field; SkiAPI fills gaps and supplies alias names. See section 6. |
| Geometry storage | Plain Postgres. Boundary as GeoJSON in JSONB plus a bbox; geometry maths in Python inside the import command. Column shape is PostGIS-ready so a later switch is one revision. |
| Attribution | Static string in `app_constants.dart`, shown on the resort detail screen footer and the Settings/About screen. |
| SkiAPI conditions | Out of scope. Raw payloads are retained so conditions can be read later. |
| Review workflow | `match_status = pending_review` rows on the source-record table plus a CLI script. No admin endpoint. |
| Cadence | Explicit command only. Boot import and in-process scheduler removed. Operator or external cron runs it. |
| Existing rows | Preserve UUIDs. Phase 1 matches legacy resorts to OpenSkiData ski areas; unmatched legacy rows go to review, never orphaned. |
| Architecture | Approach A: raw source records plus a re-runnable merge. |
| Recency | Never a merge rule. Neither source exposes per-field timestamps. |

## 4. Data model (Alembic revision `0016_resort_catalog_sources`)

### 4.1 `resort_source_records` (new)

| Column | Type | Notes |
|---|---|---|
| id | UUID PK | |
| source | text, check in (`openskidata`, `ski_api`) | |
| external_id | text | OpenSkiData ski area `id`; SkiAPI `slug` |
| payload | JSONB | raw feature (properties plus geometry) or raw API object, untouched |
| content_hash | text | sha256 of the canonical JSON payload |
| fetched_at | timestamptz | |
| snapshot_built_at | timestamptz null | OpenSkiData `metadata.json` build time; null for SkiAPI |
| missing_since | timestamptz null | set when absent from the latest snapshot of its source; cleared when it returns |
| resort_id | UUID FK resorts null, ON DELETE SET NULL | |
| match_status | text, check in (`linked`, `pending_review`, `rejected`) | |
| match_method | text null, check in (`primary`, `auto`, `manual`, `legacy`) | set only when `linked` |
| match_score | float null | |
| match_candidates | JSONB null | list of `{resort_id, name, score, distance_m, name_similarity, inside_boundary}`; populated only for `pending_review` |
| created_at, updated_at | timestamptz | |

Constraints: unique (source, external_id); index on resort_id; index on
(source, match_status).

### 4.2 `resort_field_overrides` (new)

| Column | Type | Notes |
|---|---|---|
| id | UUID PK | |
| resort_id | UUID FK resorts, ON DELETE CASCADE | |
| field | text, check in the mergeable field list | `name`, `country`, `country_code`, `region`, `region_code`, `city`, `latitude`, `longitude`, `elevation_base_m`, `elevation_top_m`, `is_active` |
| value | JSONB | typed per field; validated by the service before insert |
| note | text null | |
| created_at | timestamptz | |

Unique (resort_id, field). Manual links and rejections are not overrides;
they live on the source record (`match_method = manual`, or
`match_status = rejected`) and re-imports never touch them.

### 4.3 `resorts` (changed)

Added: `boundary` JSONB null (GeoJSON Polygon or MultiPolygon, coordinates
`[lon, lat]` as in GeoJSON), `bbox_min_lat`, `bbox_min_lon`, `bbox_max_lat`,
`bbox_max_lon` (float null), `country_code` char(2) null, `region_code`
text null (ISO 3166-2), `name_aliases` JSONB not null default `[]`,
`field_provenance` JSONB not null default `{}`, `last_merged_at`
timestamptz null.

Removed: `external_source`, `external_id`, `last_source_sync_at`, the unique
constraint (external_source, external_id), and the unique constraint (name,
country, region). Identity now lives in `resort_source_records`; OSM contains
same-name ski areas within one region, so the name constraint would break
imports. The index on `name` stays.

Data migration inside the same revision: for every row with a non-null
`external_source`, insert a `resort_source_records` row with that source and
id, `match_status = linked`, `match_method = legacy`, `fetched_at =
last_source_sync_at` (or now), and a payload rebuilt from the row's columns
(`{"legacy": true, "name": ..., "country": ..., "region": ..., "city": ...,
"latitude": ..., "longitude": ..., "elevation_base_m": ...,
"elevation_top_m": ...}`). `field_provenance` for those rows is set to the
legacy source name for every non-null field. The downgrade reverses the copy
for rows whose single linked record has `match_method = legacy`.

`ResortPublic` is unchanged; the new columns are not exposed.

### 4.4 `resort_lifts` (changed)

Added: `source` text not null, server default `overpass` (existing rows),
check in (`overpass`, `openskidata`); `status` text null;
`source_record_id` UUID FK `resort_source_records` null, ON DELETE SET NULL.

Unchanged: `polyline` stays JSON text `[[lat, lon], ...]`;
`external_track_id` stays `osm:way:<id>`. For OpenSkiData lifts the track id
is derived from the `sources` entry whose type is `openstreetmap`
(`way/123` becomes `osm:way:123`); a lift without an OSM source falls back to
`openskidata:<feature id>`. `base_altitude_m` and `top_altitude_m` are filled
from the first and last 3D coordinate. Existing session actions that stored
an `external_track_id` keep matching because the scheme is unchanged.

A lift listed under several ski areas produces one `resort_lifts` row per
linked resort. Unique index on (resort_id, external_track_id).

## 5. Import pipeline

### 5.1 OpenSkiData source (`app/services/openskidata_source.py`)

- Constructor takes `base_url`, `timeout_seconds`, an optional
  `httpx.Client`, and an optional local directory. With a directory it reads
  `metadata.json`, `ski_areas.geojson`, `lifts.geojson` from disk (offline
  runs, tests). Otherwise it streams each file to a temp directory.
- Parsing uses `ijson` (new runtime dependency) to iterate `features.item`
  without loading the 116 MB lifts file into memory.
- Boundary failures (`httpx.HTTPError`) raise `ServiceUnavailableError`;
  malformed JSON or a feature missing required keys raises `ValidationError`.
- Filters: ski areas require `downhill` in `activities` and `status` in
  {`operating`, null}; lifts require the same status rule and a `liftType`
  in the existing five-type mapping (`chair_lift` to chair; `gondola`,
  `cable_car`, `mixed_lift` to gondola; `drag_lift`, `platter`, `rope_tow`,
  `j-bar` to surface; `t-bar` to tbar; `magic_carpet` to magic_carpet).
  `funicular` and `railway` are skipped and logged.
- Optional `--countries` filter applies to ski areas by
  `places[0].iso3166_1Alpha2`; lifts follow their ski areas.
- Yields `ExternalSourceRecord(source, external_id, payload, content_hash,
  snapshot_built_at)` for ski areas and `ExternalLiftRecord(external_id,
  ski_area_ids, name, lift_type, osm_aerialway, status, polyline,
  base_altitude_m, top_altitude_m, external_track_id)` for lifts.

### 5.2 Mapping (`app/services/openskidata_mapping.py`, pure)

`map_ski_area(payload) -> SourceResortView`:

- name: `properties.name`, trimmed; null names are allowed in the view and
  fail the name check in merge.
- point: for `Point` geometry the coordinates; for polygons the centroid of
  the largest ring (shoelace formula), computed once here.
- boundary and bbox: polygons only.
- country, country_code, region, region_code, city: from `places[0]`
  (`localized.en.country`, `iso3166_1Alpha2`, `localized.en.region`,
  `iso3166_2`, `localized.en.locality`).
- elevation_top_m / elevation_base_m: `statistics.maxElevation` /
  `statistics.minElevation`, rounded to int.
- lift envelope: `statistics.lifts.minElevation` / `maxElevation` when
  present (used by the plausibility check even before lifts are imported).
- status, activities: passed through for the `is_active` rule.

`map_ski_api_resort` (existing) is wrapped to produce the same
`SourceResortView` shape.

### 5.3 Record upsert (`ResortSourceRecordService`)

Pass 1, ski areas: for each record, get by (source, external_id). Insert if
absent. If present and `content_hash` differs, replace payload, hash,
`fetched_at`, `snapshot_built_at`; clear `missing_since`. If unchanged, only
clear `missing_since`. After the pass, every record of that source not seen
in this run gets `missing_since = run started at` if it is null.

Pass 2, lifts: group by ski area id; for each ski area record that is
`linked`, upsert `resort_lifts` for its resort by `external_track_id`
(update name, type, aerialway, status, polyline, altitudes, source,
source_record_id) and delete that resort's `openskidata`-sourced lifts absent
from the snapshot. Legacy `overpass`-sourced lifts of a resort are deleted the
first time OpenSkiData lifts are written for it. Lifts of unlinked ski areas
are skipped.

Counts reported: created, updated, unchanged, marked missing, lifts
upserted, lifts deleted.

### 5.4 Matching engine (`app/services/resort_matching.py`, pure)

Inputs: a `MatchQuery(name, point, country_code, boundary?)` and a sequence
of `ResortCandidate(resort_id, name, name_aliases, point?, bbox?,
country_code?, has_primary_record)`.

1. Prefilter: candidates whose bbox (or point) lies within 0.5 degrees of
   latitude and longitude of the query point. Queries without a point skip
   the prefilter and score by name and country only, with the distance term
   fixed at 0.
2. Name similarity in [0, 1]: normalize both names (casefold, strip
   diacritics via NFKD, drop punctuation, remove the tokens `ski`, `resort`,
   `area`, `mountain`, `mount`, `mt`, `station`, `skigebiet`, `domaine`),
   then take the maximum over the candidate's name and aliases of
   `0.6 * difflib.SequenceMatcher(...).ratio() + 0.4 * jaccard(token sets)`.
3. Distance term in [0, 1]: 1.0 when the query point is inside the
   candidate's boundary (or the candidate point is inside the query's
   boundary), otherwise `max(0, 1 - d / 10_000 m)` by haversine.
4. Country term: 1.0 when codes match, 0.5 when either side is missing,
   0.0 on a mismatch.
5. Score = `0.55 * name + 0.35 * distance + 0.10 * country`.
6. Decision, with candidates sorted by (score desc, resort_id asc):
   - `auto` when best ≥ 0.85, margin over the runner-up ≥ 0.15 (or no
     runner-up), and (inside a boundary or haversine ≤ 5 km);
   - `pending_review` when best ≥ 0.5, or when `legacy_must_review` is set
     and no auto match was found;
   - `none` otherwise.

Returns `MatchDecision(kind, resort_id?, score?, candidates[:5])`.

### 5.5 Linking rules (`ResortCatalogImportService`)

For each OpenSkiData record after pass 1, in deterministic order
(`external_id` asc):

- Record already `linked` or `rejected`: leave it alone, unless `--rematch`
  and `match_method == auto`; `manual`, `primary` and `legacy` are never
  re-matched.
- New record: query the matcher against resorts with
  `has_primary_record = false` (legacy rows and SkiAPI-created rows). `auto`
  links to that resort (`match_method = auto`, keeps its UUID);
  `pending_review` stores candidates and leaves the resort untouched; `none`
  creates a new resort seeded from the mapped view (`match_method =
  primary`).
- A resort can have at most one `openskidata` record. If a second record
  would auto-link to a resort that already has one, it goes to
  `pending_review` instead.

For each legacy resort still without an OpenSkiData record after the loop,
the matcher runs in the other direction (legacy resort as query, OpenSkiData
records as candidates) with `legacy_must_review = true`, so every legacy row
ends up `linked` or listed for review.

Phase 2, SkiAPI records: same engine against all resorts, `legacy_must_review
= false`. SkiAPI never creates resorts automatically; `none` leaves the
record `pending_review` with an empty candidate list so the operator can
`create` it.

## 6. Merge policy (`ResortMergeService`)

### 6.1 Precedence

| Field | Order | Plausibility check |
|---|---|---|
| name | openskidata, ski_api | non-empty, ≤ 120 chars |
| name_aliases | all distinct source names other than the display name | |
| latitude, longitude | openskidata, ski_api | valid ranges; inside boundary when one exists |
| boundary, bbox | openskidata only | valid GeoJSON Polygon/MultiPolygon |
| country, country_code | openskidata, ski_api | when a boundary exists, its `places` entry decides |
| region, region_code | openskidata, ski_api | as above |
| city | openskidata (`locality`), ski_api | non-empty |
| elevation_top_m, elevation_base_m | openskidata, ski_api, derived_lifts | see 6.3 |
| is_active | rule in 6.4 | |
| lifts | openskidata only | |

Overrides (`resort_field_overrides`) beat every source for the listed fields
and set provenance `manual`.

### 6.2 Algorithm

For each resort whose linked records or overrides changed since
`last_merged_at` (or all resorts with `--force-merge`):

1. Build one `SourceResortView` per linked record via the source's mapper.
2. For each field: override if present; otherwise the first source in the
   precedence list whose value passes the check; otherwise null with
   provenance `none`. `name`, `country`, `region` are NOT NULL columns: if no
   value passes, keep the last non-empty candidate with provenance
   `unvalidated`, and if there is none, keep the current column value.
3. Write columns, `name_aliases`, `field_provenance` (field to
   `openskidata | ski_api | derived_lifts | manual | unvalidated | none`),
   `last_merged_at`.

Same inputs produce the same output regardless of import order. Re-running
with unchanged records and overrides changes nothing.

### 6.3 Elevation check

A candidate pair passes when both are integers in [0, 6000], `top > base`,
and, when a lift envelope exists (from imported lifts when present, otherwise
`statistics.lifts`), `base >= envelope_min - 150` and `top <= envelope_max +
150`. If every source fails and an envelope exists, the envelope itself is
used with provenance `derived_lifts`. Top and base are resolved as a pair so
both always come from the same source.

### 6.4 Active rule

`is_active` is true when at least one linked record has `missing_since` null
and (for OpenSkiData) `status` in {operating, null}. A resort whose only
records are missing or non-operating is deactivated. An override on
`is_active` pins it. Deactivated resorts keep their rows, lifts, sessions,
and favourites; `/v1/resorts` already filters on `is_active`.

## 7. Commands, configuration, repositories

### 7.1 Scripts (`app/scripts/`)

- `import_catalog.py`: `--source {openskidata,ski_api,all}` (default
  `openskidata`), `--path DIR`, `--countries CA,US`, `--merge-only`,
  `--rematch`, `--force-merge`, `--dry-run`. Order: source records, matching,
  merge, lifts. Prints created, updated, unchanged, missing, deactivated,
  pending-review, lifts upserted and deleted. `ServiceError` maps to exit
  code 1 with the message; unexpected exceptions propagate.
- `review_catalog_matches.py`: `list [--source S]`, `link SOURCE EXTERNAL_ID
  RESORT_ID`, `reject SOURCE EXTERNAL_ID`, `create SOURCE EXTERNAL_ID`. Each
  resolution re-runs the merge for the affected resort and, for OpenSkiData,
  writes that ski area's lifts.
- Removed: `import_resorts.py`, `import_resort_lifts.py`,
  `resort_sync_scheduler.py`, `osm_lift_catalog_service.py`,
  `osm_lift_mapping.py`, `resort_import_service.py`, the lifespan scheduler
  wiring in `main.py`, and their tests. The OSM Overpass fixtures under
  `tests/fixtures/osm/` are removed with them unless another test uses them
  (the plan verifies this).
- `docker-compose.yml` backend command becomes
  `alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000`.

### 7.2 Configuration (AppSettings, docker-compose.yml, .env.example)

Added: `OPENSKIDATA_BASE_URL` (default `https://tiles.openskimap.org`,
validator strips trailing slash and rejects empty),
`OPENSKIDATA_TIMEOUT_SECONDS` (`PositiveInt`, default 120).

Removed: `RESORT_SYNC_ENABLED`, `RESORT_SYNC_INTERVAL_DAYS`,
`OVERPASS_BASE_URL`, `OVERPASS_TIMEOUT_SECONDS`.

Unchanged: `SKI_API_BASE_URL`, `SKI_API_HOST`, `SKI_API_KEY`,
`SKI_API_PAGE_SIZE`, `SKI_API_TIMEOUT_SECONDS`. The base URL default is
revisited in Phase 2 once confirmed.

### 7.3 Repositories and protocols

New in `protocols.py`, then implemented:

- `ResortSourceRecordRepositoryProtocol`: `get_by_source_and_external_id`,
  `list_by_resort`, `list_by_source`, `list_pending_review(source?)`,
  `list_unlinked(source)`, `add`, `mark_missing_except(source, seen_ids,
  missing_since)`, `commit`, `rollback`.
- `ResortFieldOverrideRepositoryProtocol`: `list_by_resort`, `upsert`,
  `delete`, `commit`.
- `ResortRepositoryProtocol`: remove `get_by_external_ref`,
  `list_by_external_source`, `get_by_name_country_region`; add
  `list_match_candidates()` returning lightweight candidate rows (id, name,
  aliases, point, bbox, country_code, has_primary_record) and
  `list_changed_since_merge()`. `get_by_id` and the catalog methods stay.
- `ResortLiftRepositoryProtocol`: add `delete_missing_for_resort(resort_id,
  keep_track_ids, source)`; `upsert_by_external_track_id` gains the new
  columns.

Dependency wiring for scripts lives in the scripts themselves (as today);
API request wiring in `core/dependencies/resorts.py` is unchanged except for
removing the Overpass service factory.

## 8. Mobile

- `CatalogAttribution.openSkiData` constant in
  `mobile/lib/core/constants/app_constants.dart` with the exact required
  text.
- Rendered as a footer line on the resort detail screen and as an entry on
  the Settings/About screen.
- Widget tests assert both render the text. No API, Drift, or provider
  changes.

## 9. Testing

No test performs network I/O; every source is exercised through a local
directory or a fake `httpx.Client`.

Fixtures (`backend/tests/fixtures/openskidata/`): `metadata.json`,
`ski_areas.geojson` (Grouse with a polygon boundary, Cypress and Seymour as
points, one area sharing a name with Grouse in another country, one
nordic-only area, one abandoned area), `lifts.geojson` (about twelve lifts
across the three resorts, one funicular, one lift listed under two areas,
3D coordinates). Phase 2 adds a trimmed SkiAPI list page (reuse the existing
fixture) and one detail payload.

Unit tests:

- `test_openskidata_mapping.py`: centroid, bbox, places, elevations, lift
  type mapping, track id derivation, skipped types.
- `test_openskidata_source.py`: local directory read, streaming over the
  fixture, filter rules, `ServiceUnavailableError` on transport failure,
  `ValidationError` on malformed JSON, using a fake client.
- `test_resort_matching.py`: auto, pending, none, legacy must review,
  margin rule, boundary containment, name normalization, deterministic tie
  break, manual and rejected untouched.
- `test_resort_plausibility.py`: each check.
- `test_resort_merge_service.py`: precedence, fall-through, override wins,
  provenance map, aliases, NOT NULL fallbacks, idempotent second run,
  `missing_since` deactivation, `derived_lifts`.
- `test_resort_catalog_import_service.py`: end-to-end over the fixture with
  fake repositories; legacy rows keep their UUIDs; second run is a no-op.
- `test_import_catalog_script.py`, `test_review_catalog_matches_script.py`:
  argument parsing and exit codes.
- Repository tests against the test DB for the new repositories and the
  changed lift upsert/delete.
- `test_config.py`: new settings and removed ones.

QA tests:

- `test_resorts_favorites_qa.py`: `/v1/resorts` and `/v1/resorts/{id}` still
  return `ResortPublic` for merged rows (happy path); a deactivated resort is
  absent from the list and returns 404 by id (negative path).
- `test_sessions_lift_catalog_qa.py`: lift-anchored analysis works with
  `openskidata`-sourced lifts.

Quality gates: `ruff check .`, `ruff format --check .`, `mypy`,
`python -m pytest`; mobile `dart format`, `flutter analyze`, `flutter test`.

## 10. Documentation

- `docs/ARCHITECTURE_SUMMARY.md`: catalog section (sources, records, merge,
  review, commands).
- `README.md`: replace the SkiAPI boot/import and Overpass instructions with
  `import_catalog`, `review_catalog_matches`, a cron suggestion, and the
  attribution requirement.
- `.env.example`: new and removed variables.
- `docs/audit/2026-09-12-project-audit.md`: dated note that C3 is fixed and
  the 5.1 recommendation is adopted.
- This spec.

## 11. Phasing

Phase 1 (ships alone): revision 0016, OpenSkiData source and mapping,
matching engine, merge service, lift import, commands, config cleanup,
removal of boot import and scheduler, mobile attribution, docs and tests.

Phase 2: SkiAPI as a raw-record source (list plus detail for linked records
only), matching against all resorts, review flow for SkiAPI-only records,
alias names and gap filling, base URL confirmation.

Later, not planned here: runs, PostGIS, live conditions.

Note (2026-09-20): Phase 2 (SkiAPI enrichment) was implemented and then
removed. The provider this design was written against (`api.skiapi.com/v1`) is
deprecated, and no available RapidAPI product serves the `/resort` list
contract Phase 2 needed — the subscribable products are forecast/conditions
APIs. OpenSkiData, already primary for every field, is now the only source.
The legacy `ski_api` source records created by migration 0016 remain in the
database and are still read for the merge by
`app/services/legacy_resort_mapping.py`; `ski_api` therefore stays a valid
`source` value and keeps its place in the merge precedence.

## 12. Risks and mitigations

- Large downloads on a slow link: streaming to disk, configurable timeout,
  `--path` for pre-downloaded files.
- OSM name quality (null or local-language names): alias list and manual
  overrides; the name check falls back to SkiAPI in Phase 2.
- Boundary quality: point-only areas skip containment and rely on distance.
- Legacy rows that never match: they remain active and listed for review;
  nothing is deleted automatically.
- `ijson` dependency: pure-Python fallback exists; pinned in `pyproject`.
