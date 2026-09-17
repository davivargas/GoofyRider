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
- Break model: actions stay `run` and `lift` only. What follows a stop decides
  what the stop was. A stop followed by more descent is part of the run: short
  stops are absorbed, stops of 120 s or more are masked out of the run stats
  and counted as breaks, and the run is not split. A stop followed by a lift
  ends the run where the stop began. Breaks are reported as two summary
  fields, `break_count` and `break_duration_s`. Sessions imported from Slopes
  keep the actions Slopes recorded (the existing preset path).
- Success bar, set from a spike over all fourteen archives (section 9.5):
  corpus mean per-second agreement with Slopes of at least 88% and no archive
  under 75%; at least 94% of Slopes lifts found and at least 93% of our lifts
  matching a Slopes lift; at least 90% of Slopes runs found; exact run and
  lift counts on at least 8 of 14 archives. The achieved score of every
  archive is recorded and may only go up. Slopes labels that are plainly
  wrong are corrected in a reviewed overrides file.
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
FeatureFrame + LiftSpan[] --hmm.decode()--> StateSpan[] (descent | stop | unknown | lift)
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
5. Resampling to 1 Hz. Slopes and the planned adaptive sampling both thin
   samples while the rider is still (corpus: median interval 3 s, 95th
   percentile 21 s, over half of each session inside gaps longer than 10 s,
   nearly all of it stationary). A gap between two kept points is therefore
   bridged according to its implied speed (distance over time): below
   0.8 m/s the gap is filled as stationary at the first point; from 0.8 m/s
   the gap is filled by linear interpolation when it is at most 30 s long;
   a moving gap longer than 30 s is not bridged, the frame records
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

Slopes archives carry horizontal and vertical accuracy (GPS.csv columns 7
and 8) but no speed accuracy and no pressure, so the corpus exercises the
accuracy gates and the no-barometer altitude branch; that matches a phone
without a barometer.

## 6. Lift matching

`lift_matching.anchor(frame, lifts, config) -> list[LiftSpan]`.

Per second and per lift polyline, compute the distance to the nearest segment,
the bearing of that segment, and the along-line position. The track bearing
comes from positions 5 s either side and is undefined when that displacement
is under 3 m.

- A second is `near` lift L when its distance is at most 67.5 m (1.5 times
  the match radius).
- A second is `riding` lift L when its distance is at most 45 m, its
  along-line position lies between the two terminals (a rider skiing away
  from the top station in the direction of the line is past the terminal and
  does not count), its speed is at least 0.5 m/s, and the track bearing is
  within 30 degrees of the segment bearing in either direction.

A candidate span runs from one `riding` second to a later one, extended while
the next `riding` second is at most 150 s away and every second in between
is `near` (a stopped lift keeps the rider on the line; walking away breaks
the span). Standing still never starts or ends a span. A candidate becomes a
`LiftSpan` when all of these hold:

- it lasts at least 30 s and at least 35% of its seconds are `riding`;
- its end-to-end displacement is at least the smaller of 60 m and half the
  lift length;
- the median speed of its `riding` seconds is at most 12 m/s;
- direction: for `chair` and `gondola` rows the fused altitude rises by at
  least 15 m, or, for lifts whose OSM type was `gondola`, `cable_car`, or
  `mixed_lift` only, falls by at least 15 m (a download); for `surface`,
  `tbar`, and `magic_carpet` rows the altitude change is at least -2 m and
  the median riding speed is at most 3.5 m/s. Skiing down underneath a chair
  therefore never matches.

Overlapping spans for different lifts keep the longer one. To support the
download rule, `resort_lifts` needs the OSM `aerialway` value, so the import
stores it in a new nullable column `osm_aerialway` (added in revision
`0015_analyzer_output_fields`), and the analyzer `ResortLift` dataclass gains
`osm_aerialway: str | None`.

Each `LiftSpan` carries `lift_name` and `external_track_id`; `ActionRecord`
gains an internal `lift_name: str | None` that is stored on
`ride_session_actions` (nullable column) but not yet exposed in the API.
Revision `0015_analyzer_output_fields` adds this column, `osm_aerialway`, and
the two break fields of section 8 together, as one schema change for the new
analyzer output.

Sessions without `resort_id`, or with an empty catalog, skip this stage.

## 7. State decoding

`hmm.decode(frame, anchored, config) -> list[StateSpan]` runs Viterbi over
each stretch between anchored lift spans.

States: `descent`, `stop`, `unknown`, and `lift`. The `lift` state is always
enabled, because OSM misses some lifts; section 8 validates the fallback
lifts it produces. Short versus long stops and in-run
versus between-action stops are not HMM states; section 8 derives them from
duration and neighbours.

Emission log-likelihoods are piecewise-constant functions of the features,
defined in `config.py` as tables so they can be swept:

| State | speed (m/s) | vrate (m/s) | heading_var | gap |
|---|---|---|---|---|
| descent | > 2.0 likely, 0.8 to 2.0 possible | < -0.3 likely, -0.3 to 0.3 possible | any | must be False |
| stop | < 0.8 likely, 0.8 to 1.5 possible (shuffling, walking) | -0.3 to 0.3 | any | must be False |
| lift (fallback) | 1.0 to 10.0 likely, under 1.0 possible | > 0.15 likely, -0.1 to 0.15 possible | low likely | must be False |
| unknown | any | any | any | must be True |

Transition probabilities encode expected dwell times (descent 120 s, stop
60 s, fallback lift 240 s) and make `descent` to `lift` without an
intervening `stop` unlikely but possible. `unknown` to any state is free.

## 8. Action building and summary

`actions.build(spans, frame, overrides, config) -> (list[ActionRecord], BreakStats)`.

Stop spans are classified by what surrounds them:

| Before | After | Meaning | Effect |
|---|---|---|---|
| descent | descent | stop inside a run | merged into the run; if 120 s or longer its seconds are masked out of the run stats and it counts as a break |
| descent | lift, or end of session | run ended at the stop | run ends at the stop start; the stop belongs to no action; counts as a break if 120 s or longer |
| lift, or start of session | descent | getting ready | run starts when the stop ends; counts as a break if 120 s or longer |
| lift | lift | transfer between lifts | belongs to no action; counts as a break if 120 s or longer |

When a catalog exists, a stop that lies within 80 m of a lift base terminal
is treated as "before a lift" even if a short descent follows (skiing the
last metres into the lift line), so the run ends at that stop.

Validity rules, applied per span before runs are assembled:

- A descent span that covers less than 25 m is a stop.
- A fallback lift span (not anchored to a catalog line) must last at least
  60 s, gain at least 20 m, have a median speed of at most 8 m/s, and lie
  mostly inside the resort area; otherwise it is a stop. The resort area is
  the bounding box of all lift polylines padded by 400 m, and is undefined
  without a catalog.
- A stop or unknown span between two lift spans of at most 300 s with at
  most 40 m of displacement is a lift stoppage and merges the two into one
  lift.
- A descent span is invalid when any of these hold: 10 or more seconds
  above 28 m/s (vehicle); altitude change under 3 m with a mean speed above
  8 m/s for at least 15 s (zip line, snowmobile, frozen altitude); it starts
  below the lowest base altitude of any lift ridden in the session plus 10 m
  (leaving the resort); most of it lies outside the resort area.

Run assembly:

- A run chain is a sequence of descent spans, valid or invalid, joined across
  stop and unknown spans (an unknown span longer than 600 s breaks the
  chain, as does a stop longer than `max_in_run_break_s`, default 3600).
- Invalid spans are trimmed from both ends of a chain. Spans that drop less
  than 3 m are additionally trimmed from the tail only: Slopes and riders
  both treat the slow traverse away from a lift as the start of the run, but
  flat movement after the last real descent is not part of it. Invalid or
  flat spans in the middle of a chain stay in the run (cat tracks).
- The trimmed chain becomes a run when it lasts at least 20 s and drops at
  least 15 m from start to end.
- Masked seconds (in-run stops of 120 s or longer) are excluded from the
  `duration_s`, distance, and average and minimum speed of a run;
  `started_at` and `ended_at` still span the whole run. This differs from
  today, where masked samples still count toward wall-clock duration.
- Sequence indices, top speed, top-speed location, and altitude fields are
  computed as today from the original points mapped to each span.
  `MIN_ACTION_DURATION_S` (2 s) remains as a final guard.

`break_count` and `break_duration_s` cover every stop of 120 s or longer
between the start of the first action and the end of the last action.

`SessionSummaryFields` gains `break_count: int` and `break_duration_s: float`.
`SessionSummary` (schema) and `ride_sessions` (model, default 0, in revision
`0015_analyzer_output_fields` with the `lift_name` column of section 6) gain
the same two fields. `SessionActionRead` is unchanged.

For the corpus comparison, Slopes counts a run from its first to its last
moving second including the stops inside it, which is what `started_at` and
`ended_at` give; the per-second agreement in section 9 therefore labels the
whole `started_at` to `ended_at` span of each run as `run`.

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

### 9.3 Metrics, overrides, and the regression gate

Per archive the scorer reports: per-second agreement over `run`, `lift`,
`other`; run and lift count deltas; and action-level matches, where a
reference action is found when some action of ours of the same type overlaps
at least half of it, and one of ours is correct when it overlaps a reference
action the same way. Corpus lift and run recall and precision are sums over
all archives.

`backend/tests/fixtures/slopes/label_overrides.json` corrects Slopes labels
that are plainly wrong. Each entry names the archive, the action start time,
the corrected type (`run`, `lift`, or `other`), and a reason. It starts with
one entry: March 13 2026 Grouse Mountain, the lift from offset 10577 s to
12021 s, corrected to `other` because the rider walks the summit plateau at
about 1.3 m/s gaining 20 m in 24 minutes. Additions need the same evidence
and are reviewed by the user.

`backend/tests/fixtures/slopes/expected_scores.json` records, per archive,
the agreement and counts achieved at tuning time. `tests/unit/test_analyzer_corpus.py`
asserts that every archive scores at least its recorded agreement minus 0.5
points, that the corpus targets in section 1 hold, and that the corpus mean
is above the 78.4% of the old analyzer. Lowering a recorded score requires
editing the file in the same commit.

### 9.4 Unit and QA tests

- `signal`: synthetic sequences for each gate, a 30 s gap, pressure with and
  without GPS drift.
- `lift_matching`: a synthetic two-vertex lift with tracks that ride it,
  cross it, and ski parallel 80 m away.
- `hmm`: hand-built frames yielding a descent with a 40 s stop, a 5-minute
  stop, a sparse stationary gap, and a fallback lift.
- `actions`: each row of the stop-context table, lift-terminal proximity,
  masking of long in-run breaks, break stats, noise dropping, unknown-gap
  splitting.
- QA: points batch accepts and stores `pressure_hpa`; session detail returns
  the break fields; lift import script against the recorded fixture.
- Mobile: Drift migration test, point and summary mapper tests, contract
  fixture parse test, bridge payload test for `pressureHpa`.

### 9.5 Spike evidence (2026-09-17)

A throwaway spike (kept outside git in
`.superpowers/spikes/2026-09-17-gps-segmentation/`, with the three Overpass
responses it used) scored the fourteen archives:

| Analyzer | Per-second agreement | Exact counts | Slopes lifts found | Lifts output | Runs output (Slopes: 115) |
|---|---|---|---|---|---|
| Production `analyzer@1` | 78.4% | 0 of 14 | 107 of 118 | 183 | 264 |
| Spike without catalog | 84.1% | 6 of 14 | 101 of 118 | 106 | 109 |
| Spike with OSM catalog | 86.1% | 7 of 14 | 111 of 118 | 114 | 107 |

The spike has no heading feature, no masking, no label overrides, and only a
few hours of tuning, so the section 1 targets sit a little above it. The
remaining disagreement is mostly Slopes starting runs during very slow
movement and ending lifts a little earlier than the line geometry does.

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
