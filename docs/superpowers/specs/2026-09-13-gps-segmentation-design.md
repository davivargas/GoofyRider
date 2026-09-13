# GPS segmentation quality: design

Date: 2026-09-13. Status: approved in brainstorming, awaiting written review.
Sub-project 4 of the 2026-09-12 audit (`docs/audit/2026-09-12-project-audit.md`,
section 6). Backend `SessionAnalyzer` is the source of truth for run, lift, and
stop classification; the mobile pipeline stays transitional and gains no
classification logic.

## 1. Goals and decisions

Goals, in priority order:

1. Classify descent, lift, short stop, and long break correctly, measured
   against the fourteen Slopes archives the user recorded at Grouse, Cypress,
   and Seymour.
2. Improve speed and altitude accuracy on the backend, with a barometer feed
   from the Android app.
3. Build the resort lift catalog from OpenStreetMap so lifts are matched to
   real lift lines.

Decisions taken during brainstorming:

- Lift catalog: yes, imported from OSM `aerialway` ways via the Overpass API.
- Break model: actions stay `run` and `lift` only. Long breaks split runs and
  are reported as two summary fields, `break_count` and `break_duration_s`.
  Short stops are absorbed into runs, as Slopes does.
- Success bar: per-second state agreement with Slopes of at least 95% and
  exact run and lift counts on at least 12 of 14 archives; the other two are
  named in the expected-scores file with a reason.
- Signal scope: backend conditioning plus a native barometer sample on each
  fix. No change to the mobile pipeline beyond carrying the new field.
- Classifier: lift-anchored segmentation plus a hand-tuned hidden Markov
  model (HMM) decoded with Viterbi. No machine-learning dependency.

Out of scope, recorded for later: exposing lift and run names in the API and
on the map, piste matching, removal of the mobile pipeline (rebuild Steps
8 to 12), iOS.

## 2. Architecture

`app/services/session_analyzer.py` (834 lines) is replaced by a package
`app/services/analysis/` with the same public entry point. `SessionAnalyzer`,
`AnalyzerInput`, `AnalysisResult`, `RawPoint`, `PresetAction`,
`OverrideSpan`, `ResortLift`, `ActionRecord`, `OverrideRecord`, and
`SessionSummaryFields` keep their names and are re-exported from
`app/services/analysis/__init__.py`; `app/services/session_analyzer.py`
becomes a two-line shim importing from the package so existing imports and
CLAUDE.md references keep working.

Modules and responsibilities:

| Module | Responsibility | Depends on |
|---|---|---|
| `analysis/config.py` | `AnalyzerConfig` frozen dataclass holding every tunable constant with the defaults in sections 5 to 8 | nothing |
| `analysis/signal.py` | quality gates, 1 Hz resampling, altitude fusion, feature series (`FeatureFrame`) | `config`, `geo` |
| `analysis/lift_matching.py` | anchored lift spans from resort lift polylines | `config`, `geo` |
| `analysis/hmm.py` | state decoding between anchored lifts | `config` |
| `analysis/actions.py` | spans to `ActionRecord`s, break stats, summary fields | `config`, `geo` |
| `analysis/analyzer.py` | `SessionAnalyzer.analyze()` orchestration, preset and override precedence, validation | all of the above |
| `analysis/geo.py` | haversine, bearing, point-to-segment distance | nothing |

Data flow for a live session:

```
RawPoint[] --signal.condition()--> FeatureFrame (1 Hz arrays)
FeatureFrame + ResortLift[] --lift_matching.anchor()--> LiftSpan[]
FeatureFrame + LiftSpan[] --hmm.decode()--> StateSpan[] (descent | short_stop | long_break | unknown | lift)
StateSpan[] + overrides --actions.build()--> ActionRecord[], SummaryFields(break_count, break_duration_s, ...)
```

Preset actions (Slopes import) and manual overrides keep today's precedence:
presets replace decoded runs and lifts; overrides replace decoded state in
their span. Break stats are still computed from the decoder for imported
sessions.

## 3. Lift catalog import

### 3.1 Service

`app/services/osm_lift_catalog_service.py`, class `OsmLiftCatalogService`,
with an injectable `httpx.Client`, following `ResortCatalogService` and the
weather service. It queries the public Overpass API
(`https://overpass-api.de/api/interpreter`, overridable by the setting
`OVERPASS_BASE_URL`) with:

```
[out:json][timeout:60];
way["aerialway"](around:{radius_m},{lat},{lon});
out geom;
```

Radius defaults to 6000 m (`--radius-m` on the script). The request carries
a `User-Agent: FallLine/1.0 (+local)` header and the service sleeps 1 s
between requests. HTTP errors, timeouts, and malformed JSON raise
`ServiceUnavailableError`; a resort without latitude and longitude raises
`ValidationError`.

### 3.2 Mapping

Each way becomes one `resort_lifts` row:

| Column | Value |
|---|---|
| `name` | `tags.name`, else `Unnamed <lift_type>` |
| `lift_type` | `chair_lift` to `chair`; `gondola`, `cable_car`, `mixed_lift` to `gondola`; `drag_lift`, `platter`, `rope_tow`, `j-bar` to `surface`; `t-bar` to `tbar`; `magic_carpet` to `magic_carpet`; any other value (for example `goods`, `station`, `zip_line`) is skipped and logged at INFO |
| `polyline` | JSON array of `[lat, lon]` pairs in way order (the column is already `Text`) |
| `base_altitude_m`, `top_altitude_m` | from `ele` tags on the first and last nodes when present, else null |
| `external_track_id` | `osm:way:<id>`; re-runs update the existing row instead of inserting |

Ways with fewer than two nodes are skipped. Direction (which end is the base)
is left to the analyzer, which uses the track's vertical rate.

### 3.3 Script and repository

`python -m app.scripts.import_resort_lifts --resort "<name or id>"` and
`--all-favourites`. `ResortLiftRepositoryProtocol` gains
`upsert_by_external_track_id(resort_id, rows) -> int`. The README gains a
"Lift catalog" section with the command for the three local resorts.

### 3.4 Tests

`tests/fixtures/osm/overpass_grouse.json` is a recorded Overpass response.
Unit tests cover mapping, skipping, upsert, and the error translation; no
test performs network I/O.

## 4. Point contract: barometric pressure

### 4.1 Native

`AndroidFusedLocationBridge` registers a `Sensor.TYPE_PRESSURE` listener at
`SENSOR_DELAY_NORMAL` when tracking starts and unregisters it when tracking
stops. Each fix payload gains `pressureHpa`: the latest reading if it is
younger than 5 s, else null. Devices without a barometer send null.

### 4.2 Contract

`SessionPointInput` and `SessionPointRead` gain `pressure_hpa: float | None`
with bounds 300 to 1100. The `session_points` table gains a nullable
`pressure_hpa` numeric column in Alembic revision `0014_session_point_pressure`.
Mobile: Drift `session_points` gains `pressureHpa` (schema version bump and
migration), the point mapper and batch upload include it, the Dart pipeline
ignores it.

The shared contract fixture named in CLAUDE.md does not exist yet. This
sub-project creates `backend/tests/fixtures/contracts/session_point_batch.json`
and `backend/tests/fixtures/contracts/session_detail.json`, copies them to
`mobile/test/fixtures/contracts/` with `backend/app/scripts/sync_contract_fixtures.py`,
and adds a parse test on each side. A CI check compares the two copies.

## 5. Signal conditioning

`signal.condition(points, config) -> FeatureFrame`, applied in this order:

1. Timestamp gate: a point whose `recorded_at` is not later than the last
   kept point is dropped.
2. Horizontal accuracy gate: `accuracy_m > 30` drops the point (today's rule).
3. Jump gate: implied speed to the last kept point above 40 m/s drops the
   point.
4. Speed trust: platform speed is used when `speed_accuracy_mps` is null or
   below 3 m/s; otherwise speed is recomputed from consecutive positions.
   Top-speed reporting keeps the existing 2x spike ratio against a 1 m/s
   reference floor.
5. Resampling to 1 Hz by linear interpolation of position, altitude, and
   speed for gaps up to 10 s. Longer gaps are not bridged; the frame records
   `gap = True` for those seconds and the decoder treats them as `unknown`.
6. Altitude fusion. With pressure: barometric altitude
   `44330 * (1 - (p / 1013.25) ** 0.1903)` plus an offset that tracks GPS
   altitude with an exponential filter of time constant 300 s, weighted by
   `1 / max(vertical_accuracy_m, 3)`. Without pressure: exponential smoother
   over GPS altitude with a 10 s window and the same weighting. Vertical rate
   is the central difference of fused altitude over 5 s.
7. Heading consistency: circular variance of bearing over a 10 s window
   (bearing from platform when present, else from consecutive positions).

`FeatureFrame` holds parallel arrays: `t` (seconds from start), `lat`, `lon`,
`alt`, `speed`, `vrate`, `heading_var`, `hacc`, `gap`, plus the mapping from
each second to the nearest original point index (for top-speed location and
override application).

Slopes archives carry neither accuracy nor pressure, so the corpus exercises
the fallback branches; that matches a phone without a barometer.

## 6. Lift matching

`lift_matching.anchor(frame, lifts, config) -> list[LiftSpan]`.

For every second and every lift polyline, compute the perpendicular distance
to the nearest segment and the absolute bearing difference between the track
and that segment (either direction). A second is "on lift L" when distance
is at most 40 m and bearing difference at most 25 degrees. Consecutive
windows of at least 60 s in which at least 80% of seconds are on the same
lift and net altitude change is positive become a candidate span. The span
is extended to the first and last on-lift seconds and its ends snap to the
polyline end points when within 60 m, so lift actions start at the base and
end at the top. Overlapping candidates for different lifts keep the one with
the higher on-lift fraction. Each `LiftSpan` carries `lift_name` and
`external_track_id`; `ActionRecord` gains an internal `lift_name: str | None`
that is stored on `ride_session_actions` (nullable column) but not yet
exposed in the API. Revision `0015_analyzer_output_fields` adds this column
and the two break fields of section 8 together, as one schema change for
the new analyzer output.

Sessions without `resort_id`, or with an empty catalog, skip this stage.

## 7. State decoding

`hmm.decode(frame, anchored, config) -> list[StateSpan]` runs Viterbi over
each stretch between anchored lift spans.

States: `descent`, `short_stop`, `long_break`, `unknown`, and `lift`
(the `lift` state is enabled only when no catalog is available).

Emission log-likelihoods are piecewise-constant functions of the features,
defined in `config.py` as tables so they can be swept:

| State | speed (m/s) | vrate (m/s) | heading_var | gap |
|---|---|---|---|---|
| descent | > 2.0 likely, 0.8 to 2.0 possible | < -0.3 likely, -0.3 to 0.3 possible | any | must be False |
| short_stop | < 0.8 likely | -0.3 to 0.3 | any | must be False |
| long_break | < 1.5 likely (walking allowed) | -0.3 to 0.3 | high likely | must be False |
| lift (fallback) | 1.0 to 10.0 | > 0.3 likely | low likely | must be False |
| unknown | any | any | any | must be True |

Transitions carry duration priors: `short_stop` has an expected dwell of
30 s and a hard cap of 90 s (after 90 s the only allowed successors are
`long_break` or `descent`); `long_break` has a minimum dwell of 120 s;
`descent` to `descent` across an `unknown` stretch under 10 s costs nothing;
`unknown` to any state is free. Self-transition probabilities are set so
the expected dwell of `descent` is 120 s and of `lift` 240 s.

## 8. Action building and summary

`actions.build(spans, frame, overrides, config) -> (list[ActionRecord], BreakStats)`.

- `short_stop` spans merge into the adjacent `descent` on both sides.
- A `long_break` ends the run before it and starts a new run after it;
  `break_count += 1` and `break_duration_s += span duration`.
- `unknown` spans neither count as breaks nor split runs, unless longer than
  600 s, in which case the run is split without a break.
- Descent spans shorter than 20 s or with less than 15 m of vertical drop
  are dropped.
- Anchored and fallback lift spans become `lift` actions.
- Sequence indices, distances, average and top speed, top-speed location,
  and altitude fields are computed as today from the original points mapped
  to each span. `MIN_ACTION_DURATION_S` (2 s) remains as a final guard.

`SessionSummaryFields` gains `break_count: int` and `break_duration_s: float`.
`SessionSummary` (schema) and `ride_sessions` (model, default 0, in revision
`0015_analyzer_output_fields` with the `lift_name` column of section 6) gain
the same two fields. `SessionActionRead` is unchanged.

## 9. Evaluation

### 9.1 Corpus

All fourteen archives from `goofy-rider/slopes-files/` are copied to
`backend/tests/fixtures/slopes/` using the existing `<resort>_<date>.slopes`
naming (about 1.6 MB). `tests/unit/slopes_labels.py` turns each archive's
Run and Lift actions into a per-second label series (`run`, `lift`, `other`)
over the recording window.

### 9.2 Scoring

`app/scripts/evaluate_analyzer.py` (importable) runs the analyzer over every
archive, once without a catalog and once with the recorded lift fixture for
that resort when present, and reports per archive: per-second agreement
(analyzer state mapped to `run`, `lift`, `other`), run-count delta,
lift-count delta, descent-vertical delta. It prints a table and writes a JSON
report. `--config key=value` overrides any `AnalyzerConfig` field.

### 9.3 Regression gate

`backend/tests/fixtures/slopes/expected_scores.json` records, per archive,
the agreement and counts achieved at tuning time, plus for the up-to-two
archives that miss the bar a `reason` string. `tests/unit/test_analyzer_corpus.py`
asserts that every archive scores at least its recorded agreement minus 0.5
points with matching counts, and that the corpus targets in section 1 hold.
Lowering a recorded score requires editing the file in the same commit.

### 9.4 Unit and QA tests

- `signal`: synthetic sequences for each gate, a 30 s gap, pressure with and
  without GPS drift.
- `lift_matching`: a synthetic two-vertex lift with tracks that ride it,
  cross it, and ski parallel 80 m away.
- `hmm`: hand-built frames yielding a 40 s stop inside a run, a 5-minute
  lodge stop, and a fallback lift.
- `actions`: break stats, noise dropping, unknown-gap splitting.
- QA: points batch accepts and stores `pressure_hpa`; session detail returns
  the break fields; lift import script against the recorded fixture.
- Mobile: Drift migration test, point and summary mapper tests, contract
  fixture parse test, bridge payload test for `pressureHpa`.

## 10. Rollout

- `analyzer_version` becomes `analyzer@2026.09-hmm`. Stored actions from the
  previous version remain until re-analyzed.
- `python -m app.scripts.reanalyze_sessions --older-than-version <v>` walks
  sessions in batches of 50 and re-runs the existing analyze service path.
- Mobile session detail stats card gains one row, "Breaks", showing
  `break_count` and `break_duration_s`.
- Docs: `ARCHITECTURE_SUMMARY.md` (analysis package layout), README (lift
  import, re-analysis), `TEST_PLAN.md` (corpus gate), and the audit's
  section 2.2 note that Step 12 revalidation is superseded by this design.

## 11. Configuration additions

| Setting | Default | Purpose |
|---|---|---|
| `OVERPASS_BASE_URL` | `https://overpass-api.de/api/interpreter` | lift import endpoint |
| `OVERPASS_TIMEOUT_S` | 60 | request timeout |

Analyzer constants are code, not settings; they live in `AnalyzerConfig`.

## 12. Risks

- Overpass availability is best effort; the import is a manual, offline
  step and never runs in a request path.
- Barometer drift is handled by the GPS-tracking offset; a phone with a
  faulty barometer produces the same output as one without.
- The HMM is hand-tuned on three resorts; the config sweep and the recorded
  scores make later re-tuning cheap and visible.
