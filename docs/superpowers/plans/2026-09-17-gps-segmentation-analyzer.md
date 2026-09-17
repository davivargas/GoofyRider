# GPS Segmentation Analyzer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-sample threshold classifier in the backend `SessionAnalyzer` with a lift-anchored hidden Markov model pipeline, and gate it against the fourteen Slopes archives.

**Architecture:** A new pure package `backend/app/services/analysis/` holds seven focused modules (types, config, geo, signal, lift_matching, hmm, actions) plus the orchestrating `analyzer.py`; `app/services/session_analyzer.py` becomes a shim so every existing import keeps working. A scorer script and a corpus regression test measure agreement with the labels Slopes recorded. This plan is plan 1 of 3; database, API, lift import, and mobile changes are in the two follow-up plans and nothing here touches the database.

**Tech Stack:** Python 3.12, standard library only (no new dependencies), pytest, ruff, mypy.

**Spec:** `docs/superpowers/specs/2026-09-13-gps-segmentation-design.md` (sections 2, 5, 6, 7, 8, 9 bind this plan; sections 3, 4, 10 belong to plans 2 and 3).

## Global Constraints

- Work on branch `gps-segmentation`, created from `main`. Run `git branch --show-current` before every commit; it must print `gps-segmentation`.
- The package is pure: no database access, no HTTP, no `app.core.config` import. Bad input raises `app.services.exceptions.ValidationError`.
- No new third-party dependencies. No numpy.
- Every tunable constant lives in `AnalyzerConfig` (`analysis/config.py`). No module-level magic numbers in the other modules.
- Action types stay `run` and `lift` only. `ActionRecord.source` stays `live_analyzer` for decoded actions and `slopes_import` for presets.
- Stop rule (spec section 8): a stop followed by more descent is part of the run and is masked from run stats when it lasts 120 s or longer; a stop followed by a lift ends the run where the stop began.
- Success bar (spec section 1): corpus mean per-second agreement at least 88%, no archive under 75%, lift recall at least 94%, lift precision at least 93%, run recall at least 90%, exact run and lift counts on at least 8 of 14 archives, and corpus mean above the old analyzer's 78.4%.
- Tests perform no network I/O and need no database. Run them with `python -m pytest tests/unit/<file> -q` from `backend/`.
- Quality gates for files this plan creates or edits: `ruff check <paths>`, `ruff format --check <paths>`, `mypy <paths>` all clean. The repo has 16 older ruff errors and 12 older mypy errors elsewhere; do not fix those.
- Use `logging.getLogger(__name__)`, never `print`, inside `app/services/`. The CLI script in `app/scripts/` may print its report.
- End every commit message with a blank line and then `Claude-Session: https://claude.ai/code/session_019X8gVKYhkwgWtUPFHdpuDd`.

## File Structure

| File | Responsibility |
|---|---|
| `backend/app/services/analysis/__init__.py` | re-exports the public names |
| `backend/app/services/analysis/types.py` | dataclasses moved from `session_analyzer.py`, plus new optional fields |
| `backend/app/services/analysis/config.py` | `AnalyzerConfig`, `parse_overrides` |
| `backend/app/services/analysis/geo.py` | haversine, local projection, segment distance and bearing, circular variance |
| `backend/app/services/analysis/signal.py` | gates, 1 Hz resampling, altitude fusion, `FeatureFrame` |
| `backend/app/services/analysis/lift_matching.py` | `LiftSpan`, `anchor`, `resort_area` |
| `backend/app/services/analysis/hmm.py` | `State`, `decode` |
| `backend/app/services/analysis/actions.py` | validity rules, run chains, masking, records, break stats, summary |
| `backend/app/services/analysis/analyzer.py` | `SessionAnalyzer` orchestration, validation, preset path |
| `backend/app/services/session_analyzer.py` | shim re-exporting from the package |
| `backend/app/services/osm_lift_mapping.py` | pure mapping from an Overpass payload to lift rows (plan 2 reuses it) |
| `backend/app/scripts/evaluate_analyzer.py` | corpus loader, scorer, CLI |
| `backend/tests/fixtures/slopes/*.slopes` | the fourteen archives |
| `backend/tests/fixtures/slopes/label_overrides.json`, `expected_scores.json` | corrected labels, recorded scores |
| `backend/tests/fixtures/osm/overpass_{grouse,cypress,seymour}.json` | recorded Overpass responses |
| `backend/tests/unit/analysis/test_*.py` | one test file per module |
| `backend/tests/unit/test_analyzer_corpus.py` | regression gate |

---

### Task 1: Package skeleton, types, config, geo

**Files:**
- Create: `backend/app/services/analysis/__init__.py`, `types.py`, `config.py`, `geo.py`
- Modify: `backend/app/services/session_analyzer.py` (dataclass definitions at lines 131 to 263 move out; the old algorithm stays for now)
- Test: `backend/tests/unit/analysis/__init__.py` (empty), `backend/tests/unit/analysis/test_geo.py`, `backend/tests/unit/analysis/test_config.py`

**Interfaces:**
- Produces: every dataclass below; `AnalyzerConfig` with the field names below; `parse_overrides(pairs: Sequence[str]) -> dict[str, float | int]`; `haversine_m(lat1, lon1, lat2, lon2) -> float`; `to_local_xy(lat, lon, lat0, lon0) -> tuple[float, float]`; `segment_distance_bearing(px, py, ax, ay, bx, by) -> tuple[float, float]` (metres, degrees 0 to 360); `bearing_gap_deg(a, b) -> float` (0 to 90, direction-blind); `circular_variance(bearings_deg: Sequence[float]) -> float` (0 to 1).

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git checkout -b gps-segmentation && git branch --show-current
```
Expected output: `gps-segmentation`.

- [ ] **Step 2: Write the failing geo and config tests**

```python
# backend/tests/unit/analysis/test_geo.py
import pytest

from app.services.analysis.geo import bearing_gap_deg
from app.services.analysis.geo import circular_variance
from app.services.analysis.geo import haversine_m
from app.services.analysis.geo import segment_distance_bearing
from app.services.analysis.geo import to_local_xy


def test_haversine_one_degree_of_latitude() -> None:
    assert haversine_m(49.0, -123.0, 50.0, -123.0) == pytest.approx(111_195, rel=0.002)


def test_local_projection_matches_haversine_over_short_distances() -> None:
    x, y = to_local_xy(49.401, -123.002, 49.4, -123.0)
    planar = (x * x + y * y) ** 0.5
    assert planar == pytest.approx(haversine_m(49.4, -123.0, 49.401, -123.002), rel=0.01)


def test_segment_distance_and_bearing_for_a_north_pointing_segment() -> None:
    distance, bearing = segment_distance_bearing(30.0, 50.0, 0.0, 0.0, 0.0, 100.0)
    assert distance == pytest.approx(30.0)
    assert bearing == pytest.approx(0.0)


def test_segment_distance_clamps_to_the_end_vertex() -> None:
    distance, _ = segment_distance_bearing(0.0, 130.0, 0.0, 0.0, 0.0, 100.0)
    assert distance == pytest.approx(30.0)


def test_bearing_gap_is_direction_blind() -> None:
    assert bearing_gap_deg(10.0, 190.0) == pytest.approx(0.0)
    assert bearing_gap_deg(10.0, 100.0) == pytest.approx(90.0)
    assert bearing_gap_deg(350.0, 20.0) == pytest.approx(30.0)


def test_circular_variance_is_zero_for_a_straight_line_and_high_for_a_circle() -> None:
    assert circular_variance([90.0, 90.0, 90.0]) == pytest.approx(0.0, abs=1e-9)
    assert circular_variance([0.0, 90.0, 180.0, 270.0]) == pytest.approx(1.0, abs=1e-9)
```

```python
# backend/tests/unit/analysis/test_config.py
import pytest

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.config import parse_overrides
from app.services.exceptions import ValidationError


def test_with_overrides_returns_a_new_config() -> None:
    base = AnalyzerConfig()
    tuned = base.with_overrides(lift_radius_m=60.0)
    assert tuned.lift_radius_m == 60.0
    assert base.lift_radius_m == 45.0


def test_parse_overrides_keeps_int_fields_int() -> None:
    parsed = parse_overrides(["bridge_max_s=45", "still_mps=0.6"])
    assert parsed == {"bridge_max_s": 45, "still_mps": 0.6}
    assert isinstance(parsed["bridge_max_s"], int)


def test_parse_overrides_rejects_unknown_keys() -> None:
    with pytest.raises(ValidationError):
        parse_overrides(["not_a_field=1"])
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis -q`
Expected: collection error, `ModuleNotFoundError: No module named 'app.services.analysis'`.

- [ ] **Step 4: Create `types.py`**

Move these definitions verbatim out of `session_analyzer.py` into `backend/app/services/analysis/types.py`: the constants `RUN`, `LIFT`, `IGNORE`, `_LIVE_SOURCE`, `_IMPORT_SOURCE` (rename the last two to `LIVE_SOURCE` and `IMPORT_SOURCE`), and the dataclasses `RawPoint`, `SessionMetadataInput`, `PresetAction`, `OverrideSpan`, `ResortLift`, `ActionRecord`, `OverrideRecord`, `SessionSummaryFields`, `AnalyzerInput`, `AnalysisResult`. Then apply exactly these additions (all new fields have defaults, so existing callers keep working):

```python
# RawPoint: append after vertical_accuracy_m
    speed_accuracy_mps: float | None = None
    heading_deg: float | None = None
    pressure_hpa: float | None = None

# ResortLift: append after lift_type
    osm_aerialway: str | None = None
    external_track_id: str | None = None

# ActionRecord: append after source
    lift_name: str | None = None

# SessionSummaryFields: append after altitude_offset_m
    break_count: int = 0
    break_duration_s: float = 0.0
```

The file starts with:

```python
"""Input and output types of the session analyzer. Pure data, no behaviour."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from dataclasses import field
from datetime import datetime
import uuid

RUN = "run"
LIFT = "lift"
IGNORE = "ignore"
LIVE_SOURCE = "live_analyzer"
IMPORT_SOURCE = "slopes_import"
```

In `session_analyzer.py`, delete the moved definitions and import them instead, keeping the private aliases the old code uses:

```python
from app.services.analysis.types import IGNORE
from app.services.analysis.types import IMPORT_SOURCE as _IMPORT_SOURCE
from app.services.analysis.types import LIFT
from app.services.analysis.types import LIVE_SOURCE as _LIVE_SOURCE
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import AnalysisResult
from app.services.analysis.types import AnalyzerInput
from app.services.analysis.types import OverrideRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import PresetAction
from app.services.analysis.types import RawPoint
from app.services.analysis.types import ResortLift
from app.services.analysis.types import SessionMetadataInput
from app.services.analysis.types import SessionSummaryFields
```

- [ ] **Step 5: Create `config.py`**

```python
"""Every tunable constant of the analyzer, in one frozen dataclass."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from dataclasses import fields
from dataclasses import replace

from app.services.exceptions import ValidationError


@dataclass(frozen=True)
class AnalyzerConfig:
    # signal conditioning (spec section 5)
    accuracy_reject_m: float = 30.0
    jump_reject_mps: float = 40.0
    speed_accuracy_trust_mps: float = 3.0
    still_mps: float = 0.8
    bridge_max_s: int = 30
    speed_window_s: int = 5
    gps_alt_window_s: int = 15
    baro_alt_window_s: int = 5
    baro_offset_tau_s: float = 300.0
    vrate_half_window_s: int = 6
    heading_window_s: int = 10
    # decoder emissions (spec section 7)
    descent_fast_mps: float = 2.0
    descent_slow_mps: float = 0.8
    descent_vrate_mps: float = -0.3
    stop_fast_mps: float = 1.5
    lift_vrate_mps: float = 0.15
    lift_max_mps: float = 10.0
    lift_heading_var_max: float = 0.5
    # decoder transition penalties (natural-log units)
    switch_descent_stop: float = -4.0
    switch_stop_descent: float = -4.0
    switch_stop_lift: float = -5.0
    switch_lift_stop: float = -5.0
    switch_descent_lift: float = -9.0
    switch_lift_descent: float = -6.0
    # lift matching (spec section 6)
    lift_radius_m: float = 45.0
    lift_near_factor: float = 1.5
    lift_bearing_deg: float = 30.0
    lift_bearing_half_window_s: int = 5
    lift_bearing_min_move_m: float = 3.0
    lift_riding_min_mps: float = 0.5
    lift_gap_s: int = 150
    lift_min_duration_s: int = 30
    lift_riding_fraction: float = 0.35
    lift_min_move_m: float = 60.0
    lift_max_median_mps: float = 12.0
    lift_min_gain_m: float = 15.0
    low_gain_min_change_m: float = -2.0
    low_gain_max_median_mps: float = 3.5
    # action building (spec section 8)
    tiny_descent_m: float = 25.0
    fallback_lift_min_s: int = 60
    fallback_lift_min_gain_m: float = 20.0
    fallback_lift_max_median_mps: float = 8.0
    area_pad_m: float = 400.0
    lift_stoppage_max_s: int = 300
    lift_stoppage_max_move_m: float = 40.0
    vehicle_mps: float = 28.0
    vehicle_min_s: int = 10
    flat_fast_max_change_m: float = 3.0
    flat_fast_mps: float = 8.0
    flat_fast_min_s: int = 15
    base_margin_m: float = 10.0
    unknown_split_s: int = 600
    max_in_run_break_s: int = 3600
    tail_min_drop_m: float = 3.0
    min_run_s: int = 20
    min_run_drop_m: float = 15.0
    long_stop_s: int = 120
    min_action_duration_s: float = 2.0
    spike_ratio: float = 2.0
    spike_floor_mps: float = 1.0

    def with_overrides(self, **overrides: float | int) -> AnalyzerConfig:
        return replace(self, **overrides)


def parse_overrides(pairs: Sequence[str]) -> dict[str, float | int]:
    """Parse `key=value` strings into typed overrides for `with_overrides`."""
    kinds = {f.name: f.type for f in fields(AnalyzerConfig)}
    parsed: dict[str, float | int] = {}
    for pair in pairs:
        key, _, raw = pair.partition("=")
        if key not in kinds or not raw:
            raise ValidationError(f"Unknown or empty analyzer override: {pair!r}")
        parsed[key] = int(float(raw)) if kinds[key] == "int" else float(raw)
    return parsed
```

- [ ] **Step 6: Create `geo.py`**

```python
"""Small planar and spherical geometry helpers. Pure functions."""

from __future__ import annotations

from collections.abc import Sequence
import math

EARTH_RADIUS_M = 6_371_000.0
_M_PER_DEG_LAT = 110_540.0
_M_PER_DEG_LON_EQUATOR = 111_320.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def to_local_xy(lat: float, lon: float, lat0: float, lon0: float) -> tuple[float, float]:
    """Equirectangular projection in metres around (lat0, lon0). x is east, y is north."""
    x = (lon - lon0) * _M_PER_DEG_LON_EQUATOR * math.cos(math.radians(lat0))
    y = (lat - lat0) * _M_PER_DEG_LAT
    return x, y


def segment_distance_bearing(
    px: float, py: float, ax: float, ay: float, bx: float, by: float
) -> tuple[float, float]:
    """Distance from P to segment AB in metres, and the bearing of AB in degrees."""
    dx = bx - ax
    dy = by - ay
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0.0 else ((px - ax) * dx + (py - ay) * dy) / length_sq
    t = max(0.0, min(1.0, t))
    cx = ax + t * dx
    cy = ay + t * dy
    return math.hypot(px - cx, py - cy), math.degrees(math.atan2(dx, dy)) % 360.0


def bearing_gap_deg(a: float, b: float) -> float:
    """Smallest angle between two bearings, ignoring direction of travel (0 to 90)."""
    diff = abs((a - b + 180.0) % 360.0 - 180.0)
    return min(diff, 180.0 - diff)


def circular_variance(bearings_deg: Sequence[float]) -> float:
    """0 for identical bearings, 1 for bearings spread evenly around the circle."""
    if not bearings_deg:
        return 1.0
    sin_sum = sum(math.sin(math.radians(b)) for b in bearings_deg)
    cos_sum = sum(math.cos(math.radians(b)) for b in bearings_deg)
    return 1.0 - math.hypot(sin_sum, cos_sum) / len(bearings_deg)
```

- [ ] **Step 7: Create `__init__.py`**

```python
"""Session analysis pipeline. See docs/superpowers/specs/2026-09-13-gps-segmentation-design.md."""

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.types import IGNORE
from app.services.analysis.types import LIFT
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import AnalysisResult
from app.services.analysis.types import AnalyzerInput
from app.services.analysis.types import OverrideRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import PresetAction
from app.services.analysis.types import RawPoint
from app.services.analysis.types import ResortLift
from app.services.analysis.types import SessionMetadataInput
from app.services.analysis.types import SessionSummaryFields

__all__ = [
    "IGNORE",
    "LIFT",
    "RUN",
    "ActionRecord",
    "AnalysisResult",
    "AnalyzerConfig",
    "AnalyzerInput",
    "OverrideRecord",
    "OverrideSpan",
    "PresetAction",
    "RawPoint",
    "ResortLift",
    "SessionMetadataInput",
    "SessionSummaryFields",
]
```

- [ ] **Step 8: Run the new tests and the old analyzer tests**

Run: `python -m pytest tests/unit/analysis tests/unit/test_session_analyzer.py -q`
Expected: all pass (the old algorithm is unchanged; only its types moved).

- [ ] **Step 9: Gates and commit**

```bash
ruff check app/services/analysis app/services/session_analyzer.py tests/unit/analysis
ruff format --check app/services/analysis tests/unit/analysis
mypy app/services/analysis
git add app/services/analysis app/services/session_analyzer.py tests/unit/analysis
git commit -m "refactor(backend): analysis package with shared types, config, and geometry"
```

---

### Task 2: Signal conditioning

**Files:**
- Create: `backend/app/services/analysis/signal.py`
- Test: `backend/tests/unit/analysis/test_signal.py`, `backend/tests/unit/analysis/helpers.py`

**Interfaces:**
- Consumes: `RawPoint`, `AnalyzerConfig`, `haversine_m`, `circular_variance` from Task 1.
- Produces: `FeatureFrame` (fields `start: datetime`, `lat`, `lon`, `alt`, `speed`, `vrate`, `heading_var`, `hacc`: `list[float]`, `gap: list[bool]`, `point_index: list[int]`, `points: list[RawPoint]`, `used_barometer: bool`; methods `__len__`, `time_at(i) -> datetime`, `index_at(when) -> int`); `condition(points: Sequence[RawPoint], config: AnalyzerConfig) -> FeatureFrame | None` (None when fewer than two points survive the gates); `smooth_speeds_centered_mean(speeds) -> list[float]` moved here unchanged; `centered_mean(values, window) -> list[float]`.

- [ ] **Step 1: Write the shared test helper**

```python
# backend/tests/unit/analysis/helpers.py
from datetime import UTC
from datetime import datetime
from datetime import timedelta

from app.services.analysis.types import RawPoint

BASE_TIME = datetime(2026, 2, 1, 10, 0, 0, tzinfo=UTC)
DEG_LAT_PER_M = 1.0 / 110_540.0


def point(
    second: float,
    *,
    north_m: float = 0.0,
    east_m: float = 0.0,
    altitude_m: float | None = 1000.0,
    speed_mps: float | None = 0.0,
    accuracy_m: float | None = 5.0,
    vertical_accuracy_m: float | None = None,
    speed_accuracy_mps: float | None = None,
    pressure_hpa: float | None = None,
) -> RawPoint:
    return RawPoint(
        t_offset_ms=int(second * 1000),
        recorded_at=BASE_TIME + timedelta(seconds=second),
        latitude=49.4 + north_m * DEG_LAT_PER_M,
        longitude=-123.0 + east_m / (111_320.0 * 0.6508),
        altitude_m=altitude_m,
        speed_mps=speed_mps,
        accuracy_m=accuracy_m,
        vertical_accuracy_m=vertical_accuracy_m,
        speed_accuracy_mps=speed_accuracy_mps,
        pressure_hpa=pressure_hpa,
    )


def descent(start_s: int, seconds: int, *, speed: float = 8.0, drop_per_s: float = 3.0,
            north0: float = 0.0, alt0: float = 1000.0) -> list[RawPoint]:
    """One point per second moving south (decreasing north) while losing altitude."""
    return [
        point(start_s + i, north_m=north0 - speed * i, altitude_m=alt0 - drop_per_s * i, speed_mps=speed)
        for i in range(seconds)
    ]


def standstill(start_s: int, seconds: int, *, north: float, alt: float, every_s: int = 1) -> list[RawPoint]:
    return [
        point(start_s + i, north_m=north, altitude_m=alt, speed_mps=0.0)
        for i in range(0, seconds, every_s)
    ]


def climb(start_s: int, seconds: int, *, speed: float = 4.0, gain_per_s: float = 1.5,
          north0: float = 0.0, alt0: float = 700.0) -> list[RawPoint]:
    """One point per second moving north in a straight line while gaining altitude."""
    return [
        point(start_s + i, north_m=north0 + speed * i, altitude_m=alt0 + gain_per_s * i, speed_mps=speed)
        for i in range(seconds)
    ]
```

`backend/tests/` has no `__init__.py`. The import `from tests.unit.analysis.helpers import ...` works through implicit namespace packages because `pyproject.toml` sets `pythonpath = ["."]`; do not add `__init__.py` files above `tests/unit/analysis/`.

- [ ] **Step 2: Write the failing signal tests**

```python
# backend/tests/unit/analysis/test_signal.py
import pytest

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.signal import condition
from app.services.analysis.signal import smooth_speeds_centered_mean
from tests.unit.analysis.helpers import descent
from tests.unit.analysis.helpers import point

CONFIG = AnalyzerConfig()


def test_too_few_points_yields_no_frame() -> None:
    assert condition([], CONFIG) is None
    assert condition([point(0)], CONFIG) is None


def test_frame_has_one_row_per_second() -> None:
    frame = condition(descent(0, 60), CONFIG)
    assert frame is not None
    assert len(frame) == 60
    assert frame.vrate[30] == pytest.approx(-3.0, abs=0.2)
    assert frame.speed[30] == pytest.approx(8.0, abs=0.1)
    assert not any(frame.gap)


def test_gates_drop_non_monotonic_inaccurate_and_teleporting_points() -> None:
    points = descent(0, 30)
    points.insert(10, point(5.0, north_m=-40.0, altitude_m=985.0, speed_mps=8.0))  # time goes backwards
    points.insert(15, point(14.5, north_m=-116.0, altitude_m=956.0, speed_mps=8.0, accuracy_m=80.0))
    points.insert(20, point(19.5, north_m=-5000.0, altitude_m=940.0, speed_mps=8.0))  # teleport
    frame = condition(points, CONFIG)
    assert frame is not None
    assert len(frame.points) == 30
    assert min(frame.lat) > 49.4 - 300 / 110_540.0


def test_stationary_gap_is_bridged_as_a_stop() -> None:
    points = [point(0, north_m=0.0), point(1, north_m=0.0), point(400, north_m=2.0), point(401, north_m=2.0)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert len(frame) == 402
    assert max(frame.speed[5:395]) == 0.0
    assert not any(frame.gap)


def test_short_moving_gap_is_interpolated() -> None:
    points = [point(0, north_m=0.0, speed_mps=5.0), point(1, north_m=-5.0, speed_mps=5.0),
              point(21, north_m=-105.0, speed_mps=5.0), point(22, north_m=-110.0, speed_mps=5.0)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert frame.speed[11] == pytest.approx(5.0, abs=0.3)
    assert not any(frame.gap)


def test_long_moving_gap_is_marked_unknown() -> None:
    points = [point(0, north_m=0.0, speed_mps=5.0), point(1, north_m=-5.0, speed_mps=5.0),
              point(121, north_m=-605.0, speed_mps=5.0), point(122, north_m=-610.0, speed_mps=5.0)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert all(frame.gap[2:120])
    assert not frame.gap[0]


def test_untrusted_platform_speed_is_replaced_by_position_speed() -> None:
    points = [point(i, north_m=-5.0 * i, speed_mps=40.0, speed_accuracy_mps=9.0) for i in range(30)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert frame.speed[15] == pytest.approx(5.0, abs=0.3)


def test_barometer_removes_gps_altitude_noise() -> None:
    noisy = [1000.0 + (12.0 if i % 2 else -12.0) for i in range(120)]
    points = [point(i, north_m=0.0, altitude_m=noisy[i], pressure_hpa=898.7, vertical_accuracy_m=10.0)
              for i in range(120)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert frame.used_barometer
    assert max(frame.alt) - min(frame.alt) < 3.0
    assert abs(sum(frame.alt) / len(frame.alt) - 1000.0) < 8.0


def test_speed_smoothing_canonical_reference() -> None:
    raw = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0,
           9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0]
    expected = [1.6, 2.2, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 8.6, 8.8,
                8.6, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.2, 0.6]
    assert smooth_speeds_centered_mean(raw) == pytest.approx(expected, abs=1e-9)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis/test_signal.py -q`
Expected: `ModuleNotFoundError: No module named 'app.services.analysis.signal'`.

- [ ] **Step 4: Implement `signal.py`**

```python
"""Quality gates, 1 Hz resampling, altitude fusion, and the per-second feature frame."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from datetime import timedelta
import math

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import circular_variance
from app.services.analysis.geo import haversine_m
from app.services.analysis.types import RawPoint

_SEA_LEVEL_HPA = 1013.25
_MIN_VERTICAL_ACCURACY_M = 3.0
_BARO_WARMUP_S = 30.0
_LEGACY_SPEED_WINDOW = 5


@dataclass(frozen=True)
class FeatureFrame:
    """One row per second from `start`. All lists have the same length."""

    start: datetime
    lat: list[float]
    lon: list[float]
    alt: list[float]
    speed: list[float]
    vrate: list[float]
    heading_var: list[float]
    hacc: list[float]
    gap: list[bool]
    point_index: list[int]
    points: list[RawPoint]
    used_barometer: bool

    def __len__(self) -> int:
        return len(self.lat)

    def time_at(self, index: int) -> datetime:
        return self.start + timedelta(seconds=index)

    def index_at(self, when: datetime) -> int:
        raw = round((when - self.start).total_seconds())
        return max(0, min(len(self) - 1, raw))


def condition(points: Sequence[RawPoint], config: AnalyzerConfig) -> FeatureFrame | None:
    kept = _apply_gates(points, config)
    if len(kept) < 2:
        return None
    point_speeds = _point_speeds(kept, config)
    point_alts, used_barometer = _point_altitudes(kept, config)

    start = kept[0].recorded_at.replace(microsecond=0)
    offsets = [(p.recorded_at - start).total_seconds() for p in kept]
    n = int(offsets[-1]) + 1
    lat = [kept[0].latitude] * n
    lon = [kept[0].longitude] * n
    alt = [point_alts[0]] * n
    speed = [0.0] * n
    hacc = [kept[0].accuracy_m or 0.0] * n
    gap = [False] * n
    point_index = [0] * n

    for k in range(len(kept) - 1):
        a, b = kept[k], kept[k + 1]
        ia, ib = int(offsets[k]), int(offsets[k + 1])
        dt = offsets[k + 1] - offsets[k]
        implied = haversine_m(a.latitude, a.longitude, b.latitude, b.longitude) / dt
        dense = dt <= 3.5
        for i in range(ia, min(ib, n - 1) + 1):
            f = (i - ia) / max(ib - ia, 1)
            alt[i] = point_alts[k] + f * (point_alts[k + 1] - point_alts[k])
            hacc[i] = (a.accuracy_m if f < 0.5 else b.accuracy_m) or 0.0
            point_index[i] = k if f < 0.5 else k + 1
            if implied < config.still_mps:
                lat[i], lon[i] = a.latitude, a.longitude
                speed[i] = point_speeds[k] + f * (point_speeds[k + 1] - point_speeds[k]) if dense else 0.0
                continue
            lat[i] = a.latitude + f * (b.latitude - a.latitude)
            lon[i] = a.longitude + f * (b.longitude - a.longitude)
            if dense:
                speed[i] = point_speeds[k] + f * (point_speeds[k + 1] - point_speeds[k])
            else:
                speed[i] = implied
                gap[i] = dt > config.bridge_max_s
    lat[-1], lon[-1] = kept[-1].latitude, kept[-1].longitude
    alt[-1], speed[-1] = point_alts[-1], point_speeds[-1]
    point_index[-1] = len(kept) - 1

    alt_window = config.baro_alt_window_s if used_barometer else config.gps_alt_window_s
    smooth_alt = centered_mean(alt, alt_window)
    smooth_speed = centered_mean(speed, config.speed_window_s)
    return FeatureFrame(
        start=start,
        lat=lat,
        lon=lon,
        alt=smooth_alt,
        speed=smooth_speed,
        vrate=_vertical_rate(smooth_alt, config.vrate_half_window_s),
        heading_var=_heading_variance(lat, lon, config.heading_window_s),
        hacc=hacc,
        gap=gap,
        point_index=point_index,
        points=kept,
        used_barometer=used_barometer,
    )


def centered_mean(values: Sequence[float], window: int) -> list[float]:
    """Centered rolling mean whose window shrinks at the edges."""
    half = window // 2
    n = len(values)
    prefix = [0.0]
    for value in values:
        prefix.append(prefix[-1] + value)
    out: list[float] = []
    for i in range(n):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        out.append((prefix[hi] - prefix[lo]) / (hi - lo))
    return out


def smooth_speeds_centered_mean(speeds: Sequence[float]) -> list[float]:
    """Legacy reference smoother: window 5 with edge padding by boundary repeat."""
    if not speeds:
        return []
    half = _LEGACY_SPEED_WINDOW // 2
    n = len(speeds)
    out: list[float] = []
    for i in range(n):
        total = 0.0
        for k in range(-half, half + 1):
            total += float(speeds[max(0, min(n - 1, i + k))])
        out.append(total / _LEGACY_SPEED_WINDOW)
    return out


def _apply_gates(points: Sequence[RawPoint], config: AnalyzerConfig) -> list[RawPoint]:
    kept: list[RawPoint] = []
    for p in points:
        if p.accuracy_m is not None and p.accuracy_m > config.accuracy_reject_m:
            continue
        if kept:
            last = kept[-1]
            dt = (p.recorded_at - last.recorded_at).total_seconds()
            if dt <= 0:
                continue
            implied = haversine_m(last.latitude, last.longitude, p.latitude, p.longitude) / dt
            if implied > config.jump_reject_mps:
                continue
        kept.append(p)
    return kept


def _point_speeds(kept: Sequence[RawPoint], config: AnalyzerConfig) -> list[float]:
    speeds: list[float] = []
    for k, p in enumerate(kept):
        trusted = p.speed_mps is not None and (
            p.speed_accuracy_mps is None or p.speed_accuracy_mps < config.speed_accuracy_trust_mps
        )
        if trusted and p.speed_mps is not None:
            speeds.append(float(p.speed_mps))
            continue
        neighbour = kept[k - 1] if k > 0 else kept[k + 1]
        dt = abs((p.recorded_at - neighbour.recorded_at).total_seconds())
        distance = haversine_m(p.latitude, p.longitude, neighbour.latitude, neighbour.longitude)
        speeds.append(distance / dt if dt > 0 else 0.0)
    return speeds


def _point_altitudes(kept: Sequence[RawPoint], config: AnalyzerConfig) -> tuple[list[float], bool]:
    gps = [p.altitude_m for p in kept]
    first_known = next((a for a in gps if a is not None), None)
    if first_known is None:
        return [0.0] * len(kept), False
    if not all(p.pressure_hpa is not None for p in kept):
        filled: list[float] = []
        last = float(first_known)
        for a in gps:
            last = float(a) if a is not None else last
            filled.append(last)
        return filled, False

    barometric = [
        44_330.0 * (1.0 - (float(p.pressure_hpa or _SEA_LEVEL_HPA) / _SEA_LEVEL_HPA) ** 0.1903) for p in kept
    ]
    # Start from the mean GPS-minus-barometer difference of the first 30 s, so one noisy
    # first fix cannot bias the whole session. (The accuracy gate has already removed
    # outliers, and a median is degenerate for noise that alternates around the truth.)
    warmup = [
        float(a) - b
        for p, a, b in zip(kept, gps, barometric, strict=True)
        if a is not None and (p.recorded_at - kept[0].recorded_at).total_seconds() <= _BARO_WARMUP_S
    ]
    offset = sum(warmup) / len(warmup) if warmup else float(first_known) - barometric[0]
    fused: list[float] = []
    previous_time = kept[0].recorded_at
    for p, a, b in zip(kept, gps, barometric, strict=True):
        if a is not None:
            dt = (p.recorded_at - previous_time).total_seconds()
            trust = _MIN_VERTICAL_ACCURACY_M / max(
                p.vertical_accuracy_m or _MIN_VERTICAL_ACCURACY_M, _MIN_VERTICAL_ACCURACY_M
            )
            weight = min(1.0, dt / config.baro_offset_tau_s) * trust
            offset += weight * ((float(a) - b) - offset)
        previous_time = p.recorded_at
        fused.append(b + offset)
    return fused, True


def _vertical_rate(alt: Sequence[float], half_window: int) -> list[float]:
    n = len(alt)
    out: list[float] = []
    for i in range(n):
        lo, hi = max(0, i - half_window), min(n - 1, i + half_window)
        out.append((alt[hi] - alt[lo]) / (hi - lo) if hi > lo else 0.0)
    return out


def _heading_variance(lat: Sequence[float], lon: Sequence[float], window: int) -> list[float]:
    n = len(lat)
    bearings: list[float | None] = [None] * n
    for i in range(1, n - 1):
        north = (lat[i + 1] - lat[i - 1]) * 110_540.0
        east = (lon[i + 1] - lon[i - 1]) * 111_320.0 * math.cos(math.radians(lat[i]))
        if math.hypot(north, east) > 1.0:
            bearings[i] = math.degrees(math.atan2(east, north)) % 360.0
    half = window // 2
    out: list[float] = []
    for i in range(n):
        known = [b for b in bearings[max(0, i - half) : i + half + 1] if b is not None]
        out.append(circular_variance(known) if len(known) >= 3 else 1.0)
    return out
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/unit/analysis/test_signal.py -q`
Expected: 9 passed.

- [ ] **Step 6: Gates and commit**

```bash
ruff check app/services/analysis/signal.py tests/unit/analysis && ruff format --check app/services/analysis tests/unit/analysis && mypy app/services/analysis
git add app/services/analysis/signal.py tests/unit/analysis
git commit -m "feat(backend): signal conditioning with sparse-sample bridging and barometer fusion"
```

---

### Task 3: Lift matching

**Files:**
- Create: `backend/app/services/analysis/lift_matching.py`
- Test: `backend/tests/unit/analysis/test_lift_matching.py`

**Interfaces:**
- Consumes: `FeatureFrame` (Task 2), `ResortLift` with `osm_aerialway` (Task 1), geometry helpers.
- Produces: `LiftSpan(start: int, end: int, lift_name: str | None, external_track_id: str | None)`; `anchor(frame, lifts, config) -> list[LiftSpan]` sorted by start, non-overlapping; `resort_area(lifts, config) -> tuple[float, float, float, float] | None` as `(min_lat, max_lat, min_lon, max_lon)`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/unit/analysis/test_lift_matching.py
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.lift_matching import anchor
from app.services.analysis.lift_matching import resort_area
from app.services.analysis.signal import condition
from app.services.analysis.types import ResortLift
from tests.unit.analysis.helpers import DEG_LAT_PER_M
from tests.unit.analysis.helpers import climb
from tests.unit.analysis.helpers import point
from tests.unit.analysis.helpers import standstill

CONFIG = AnalyzerConfig()
# A straight lift running 800 m due north from the helper origin.
CHAIR = ResortLift(
    name="Test Chair",
    polyline=((49.4, -123.0), (49.4 + 800 * DEG_LAT_PER_M, -123.0)),
    lift_type="chair",
    osm_aerialway="chair_lift",
    external_track_id="osm:way:1",
)
GONDOLA = ResortLift(name="Test Gondola", polyline=CHAIR.polyline, lift_type="gondola",
                     osm_aerialway="gondola", external_track_id="osm:way:2")


def _frame(points):
    frame = condition(points, CONFIG)
    assert frame is not None
    return frame


def test_riding_the_line_uphill_is_anchored_with_its_name() -> None:
    spans = anchor(_frame(climb(0, 190)), [CHAIR], CONFIG)
    assert len(spans) == 1
    assert spans[0].lift_name == "Test Chair"
    assert spans[0].external_track_id == "osm:way:1"
    assert spans[0].start <= 5 and spans[0].end >= 185


def test_waiting_at_the_base_is_not_part_of_the_lift() -> None:
    points = standstill(0, 300, north=0.0, alt=700.0) + climb(300, 190)
    spans = anchor(_frame(points), [CHAIR], CONFIG)
    assert len(spans) == 1
    assert spans[0].start >= 295


def test_a_stopped_lift_stays_one_span() -> None:
    first = climb(0, 100)
    paused = standstill(100, 90, north=400.0, alt=850.0)
    second = climb(190, 90, north0=400.0, alt0=850.0)
    spans = anchor(_frame(first + paused + second), [CHAIR], CONFIG)
    assert len(spans) == 1
    assert spans[0].end - spans[0].start >= 270


def test_skiing_down_under_a_chair_is_not_a_lift() -> None:
    down = [point(i, north_m=800.0 - 8.0 * i, altitude_m=1900.0 - 3.0 * i, speed_mps=8.0) for i in range(100)]
    assert anchor(_frame(down), [CHAIR], CONFIG) == []


def test_riding_a_gondola_down_is_a_lift() -> None:
    down = [point(i, north_m=800.0 - 4.0 * i, altitude_m=1900.0 - 1.5 * i, speed_mps=4.0) for i in range(200)]
    spans = anchor(_frame(down), [GONDOLA], CONFIG)
    assert len(spans) == 1


def test_crossing_the_line_is_not_a_lift() -> None:
    across = [point(i, north_m=400.0, east_m=-200.0 + 4.0 * i, altitude_m=1000.0 + 0.5 * i, speed_mps=4.0)
              for i in range(100)]
    assert anchor(_frame(across), [CHAIR], CONFIG) == []


def test_parallel_track_eighty_metres_away_is_not_a_lift() -> None:
    beside = [point(i, north_m=4.0 * i, east_m=80.0, altitude_m=700.0 + 1.5 * i, speed_mps=4.0) for i in range(190)]
    assert anchor(_frame(beside), [CHAIR], CONFIG) == []


def test_skiing_away_past_the_top_terminal_does_not_extend_the_lift() -> None:
    ride = climb(0, 200)  # reaches 796 m north
    away = [point(200 + i, north_m=800.0 + 5.0 * i, altitude_m=1000.0 - 1.0 * i, speed_mps=5.0) for i in range(60)]
    spans = anchor(_frame(ride + away), [CHAIR], CONFIG)
    assert len(spans) == 1
    assert spans[0].end <= 206


def test_resort_area_pads_the_lift_bounding_box() -> None:
    area = resort_area([CHAIR], CONFIG)
    assert area is not None
    min_lat, max_lat, _, _ = area
    assert min_lat < 49.4 and max_lat > 49.4 + 800 * DEG_LAT_PER_M
    assert resort_area([], CONFIG) is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis/test_lift_matching.py -q`
Expected: `ModuleNotFoundError: No module named 'app.services.analysis.lift_matching'`.

- [ ] **Step 3: Implement `lift_matching.py`**

```python
"""Anchor stretches of the track to catalog lift lines (spec section 6)."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import math

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import bearing_gap_deg
from app.services.analysis.geo import segment_distance_bearing
from app.services.analysis.geo import to_local_xy
from app.services.analysis.signal import FeatureFrame
from app.services.analysis.types import ResortLift

_DOWNLOAD_AERIALWAYS = frozenset({"gondola", "cable_car", "mixed_lift"})
_LOW_GAIN_LIFT_TYPES = frozenset({"surface", "tbar", "magic_carpet"})
_BBOX_MARGIN_M = 200.0


@dataclass(frozen=True)
class LiftSpan:
    start: int
    end: int
    lift_name: str | None
    external_track_id: str | None


def resort_area(
    lifts: Sequence[ResortLift], config: AnalyzerConfig
) -> tuple[float, float, float, float] | None:
    vertices = [v for lift in lifts for v in lift.polyline]
    if not vertices:
        return None
    lats = [float(v[0]) for v in vertices]
    lons = [float(v[1]) for v in vertices]
    pad_lat = config.area_pad_m / 110_540.0
    pad_lon = config.area_pad_m / (111_320.0 * math.cos(math.radians(lats[0])))
    return min(lats) - pad_lat, max(lats) + pad_lat, min(lons) - pad_lon, max(lons) + pad_lon


def anchor(
    frame: FeatureFrame, lifts: Sequence[ResortLift], config: AnalyzerConfig
) -> list[LiftSpan]:
    usable = [lift for lift in lifts if len(lift.polyline) >= 2]
    n = len(frame)
    if not usable or n == 0:
        return []
    lat0, lon0 = frame.lat[0], frame.lon[0]
    xy = [to_local_xy(frame.lat[i], frame.lon[i], lat0, lon0) for i in range(n)]
    bearings = _track_bearings(xy, config)

    candidates: list[tuple[int, int, ResortLift]] = []
    for lift in usable:
        line = [to_local_xy(float(v[0]), float(v[1]), lat0, lon0) for v in lift.polyline]
        near, riding = _classify_seconds(frame, xy, bearings, line, config)
        candidates.extend((a, b, lift) for a, b in _spans_for_lift(frame, xy, near, riding, line, lift, config))

    candidates.sort(key=lambda c: (c[0], c[1]))
    chosen: list[tuple[int, int, ResortLift]] = []
    for cand in candidates:
        if chosen and cand[0] <= chosen[-1][1]:
            if cand[1] - cand[0] > chosen[-1][1] - chosen[-1][0]:
                chosen[-1] = cand
            continue
        chosen.append(cand)
    return [LiftSpan(a, b, lift.name, lift.external_track_id) for a, b, lift in chosen]


def _track_bearings(
    xy: Sequence[tuple[float, float]], config: AnalyzerConfig
) -> list[float | None]:
    n = len(xy)
    half = config.lift_bearing_half_window_s
    out: list[float | None] = [None] * n
    for i in range(n):
        ax, ay = xy[max(0, i - half)]
        bx, by = xy[min(n - 1, i + half)]
        if math.hypot(bx - ax, by - ay) > config.lift_bearing_min_move_m:
            out[i] = math.degrees(math.atan2(bx - ax, by - ay)) % 360.0
    return out


def _classify_seconds(
    frame: FeatureFrame,
    xy: Sequence[tuple[float, float]],
    bearings: Sequence[float | None],
    line: Sequence[tuple[float, float]],
    config: AnalyzerConfig,
) -> tuple[list[bool], list[bool]]:
    n = len(xy)
    near = [False] * n
    riding = [False] * n
    min_x = min(p[0] for p in line) - _BBOX_MARGIN_M
    max_x = max(p[0] for p in line) + _BBOX_MARGIN_M
    min_y = min(p[1] for p in line) - _BBOX_MARGIN_M
    max_y = max(p[1] for p in line) + _BBOX_MARGIN_M
    (ex, ey), (fx, fy) = line[0], line[-1]
    axis_x, axis_y = fx - ex, fy - ey
    axis_len = math.hypot(axis_x, axis_y) or 1.0
    for i, (px, py) in enumerate(xy):
        if not (min_x <= px <= max_x and min_y <= py <= max_y):
            continue
        best_distance, best_bearing = math.inf, 0.0
        for (ax, ay), (bx, by) in zip(line, line[1:], strict=False):
            distance, bearing = segment_distance_bearing(px, py, ax, ay, bx, by)
            if distance < best_distance:
                best_distance, best_bearing = distance, bearing
        if best_distance <= config.lift_radius_m * config.lift_near_factor:
            near[i] = True
        along = ((px - ex) * axis_x + (py - ey) * axis_y) / axis_len
        track_bearing = bearings[i]
        if (
            best_distance <= config.lift_radius_m
            and 0.0 <= along <= axis_len
            and track_bearing is not None
            and frame.speed[i] >= config.lift_riding_min_mps
            and bearing_gap_deg(track_bearing, best_bearing) <= config.lift_bearing_deg
        ):
            riding[i] = True
    return near, riding


def _spans_for_lift(
    frame: FeatureFrame,
    xy: Sequence[tuple[float, float]],
    near: Sequence[bool],
    riding: Sequence[bool],
    line: Sequence[tuple[float, float]],
    lift: ResortLift,
    config: AnalyzerConfig,
) -> list[tuple[int, int]]:
    indices = [i for i, flag in enumerate(riding) if flag]
    length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(line, line[1:], strict=False))
    low_gain = lift.lift_type in _LOW_GAIN_LIFT_TYPES
    can_download = lift.osm_aerialway in _DOWNLOAD_AERIALWAYS
    spans: list[tuple[int, int]] = []
    k = 0
    while k < len(indices):
        start = end = indices[k]
        m = k
        while m + 1 < len(indices):
            nxt = indices[m + 1]
            if nxt - end > config.lift_gap_s or not all(near[q] for q in range(end, nxt + 1)):
                break
            end = nxt
            m += 1
        duration = end - start + 1
        riding_count = m - k + 1
        moved = math.hypot(xy[end][0] - xy[start][0], xy[end][1] - xy[start][1])
        change = frame.alt[end] - frame.alt[start]
        speeds = sorted(frame.speed[q] for q in indices[k : m + 1])
        median = speeds[len(speeds) // 2]
        if low_gain:
            direction_ok = change >= config.low_gain_min_change_m and median <= config.low_gain_max_median_mps
        else:
            direction_ok = change >= config.lift_min_gain_m or (can_download and change <= -config.lift_min_gain_m)
        if (
            duration >= config.lift_min_duration_s
            and riding_count >= config.lift_riding_fraction * duration
            and moved >= min(config.lift_min_move_m, 0.5 * length)
            and median <= config.lift_max_median_mps
            and direction_ok
        ):
            spans.append((start, end))
        k = m + 1
    return spans
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/unit/analysis/test_lift_matching.py -q`
Expected: 9 passed.

- [ ] **Step 5: Gates and commit**

```bash
ruff check app/services/analysis/lift_matching.py tests/unit/analysis && ruff format --check app/services/analysis tests/unit/analysis && mypy app/services/analysis
git add app/services/analysis/lift_matching.py tests/unit/analysis/test_lift_matching.py
git commit -m "feat(backend): anchor lift rides to catalog lift lines"
```

---

### Task 4: State decoding

**Files:**
- Create: `backend/app/services/analysis/hmm.py`
- Test: `backend/tests/unit/analysis/test_hmm.py`

**Interfaces:**
- Consumes: `FeatureFrame`, `LiftSpan`, `AnalyzerConfig`.
- Produces: `class State(IntEnum)` with `DESCENT = 0`, `STOP = 1`, `LIFT = 2`, `UNKNOWN = 3`, `INVALID = 4` (the decoder never emits `INVALID`; Task 5 uses it); `decode(frame, anchored: Sequence[LiftSpan], config) -> list[State]` of length `len(frame)`, with every second inside an anchored span set to `State.LIFT` and the stretches between them decoded by Viterbi.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/unit/analysis/test_hmm.py
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.hmm import State
from app.services.analysis.hmm import decode
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import condition
from tests.unit.analysis.helpers import climb
from tests.unit.analysis.helpers import descent
from tests.unit.analysis.helpers import point
from tests.unit.analysis.helpers import standstill

CONFIG = AnalyzerConfig()


def _states(points, anchored=()):
    frame = condition(points, CONFIG)
    assert frame is not None
    return decode(frame, list(anchored), CONFIG)


def _share(states, state, lo, hi):
    window = states[lo:hi]
    return sum(1 for s in window if s == state) / len(window)


def test_steady_descent_is_descent() -> None:
    states = _states(descent(0, 120))
    assert _share(states, State.DESCENT, 5, 115) == 1.0


def test_a_forty_second_stop_inside_a_descent_is_a_stop() -> None:
    points = descent(0, 60) + standstill(60, 40, north=-472.0, alt=823.0) + descent(100, 60, north0=-472.0, alt0=823.0)
    states = _states(points)
    assert _share(states, State.DESCENT, 5, 50) == 1.0
    assert _share(states, State.STOP, 68, 92) == 1.0
    assert _share(states, State.DESCENT, 110, 155) == 1.0


def test_a_single_slow_second_does_not_flicker_to_stop() -> None:
    points = descent(0, 120)
    points[60] = point(60, north_m=-480.0, altitude_m=820.0, speed_mps=0.2)
    states = _states(points)
    assert _share(states, State.DESCENT, 50, 70) == 1.0


def test_sparse_stationary_samples_decode_as_one_stop() -> None:
    points = descent(0, 60) + standstill(60, 600, north=-472.0, alt=823.0, every_s=25) + descent(660, 60, north0=-472.0, alt0=823.0)
    states = _states(points)
    assert _share(states, State.STOP, 70, 650) == 1.0


def test_slow_straight_climb_is_a_fallback_lift() -> None:
    states = _states(standstill(0, 30, north=0.0, alt=700.0) + climb(30, 200, speed=2.5, gain_per_s=0.5))
    assert _share(states, State.LIFT, 45, 220) >= 0.95


def test_anchored_seconds_are_lift_regardless_of_features() -> None:
    states = _states(descent(0, 120), anchored=[LiftSpan(20, 80, "X", None)])
    assert _share(states, State.LIFT, 20, 81) == 1.0
    assert _share(states, State.DESCENT, 85, 115) == 1.0


def test_long_moving_gap_is_unknown() -> None:
    points = descent(0, 30) + descent(230, 30, north0=-1840.0, alt0=310.0)
    states = _states(points)
    assert _share(states, State.UNKNOWN, 35, 225) == 1.0
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis/test_hmm.py -q`
Expected: `ModuleNotFoundError: No module named 'app.services.analysis.hmm'`.

- [ ] **Step 3: Implement `hmm.py`**

```python
"""Viterbi decoding of descent, stop, lift, and unknown between anchored lifts (spec section 7)."""

from __future__ import annotations

from collections.abc import Sequence
from enum import IntEnum

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import FeatureFrame

_IMPOSSIBLE = -50.0
_DECODED_STATES = 4


class State(IntEnum):
    DESCENT = 0
    STOP = 1
    LIFT = 2
    UNKNOWN = 3
    INVALID = 4


def decode(
    frame: FeatureFrame, anchored: Sequence[LiftSpan], config: AnalyzerConfig
) -> list[State]:
    n = len(frame)
    states: list[State | None] = [None] * n
    for span in anchored:
        for i in range(max(0, span.start), min(n - 1, span.end) + 1):
            states[i] = State.LIFT
    i = 0
    while i < n:
        if states[i] is not None:
            i += 1
            continue
        j = i
        while j + 1 < n and states[j + 1] is None:
            j += 1
        states[i : j + 1] = _viterbi(frame, i, j, config)
        i = j + 1
    return [s if s is not None else State.STOP for s in states]


def _emissions(frame: FeatureFrame, i: int, config: AnalyzerConfig) -> list[float]:
    if frame.gap[i]:
        return [_IMPOSSIBLE, _IMPOSSIBLE, _IMPOSSIBLE, 0.0]
    speed, vrate = frame.speed[i], frame.vrate[i]

    descent = 0.0 if speed > config.descent_fast_mps else -1.5 if speed > config.descent_slow_mps else -4.0
    descent += 0.0 if vrate < config.descent_vrate_mps else -1.0 if vrate <= 0.3 else -4.0

    stop = 0.0 if speed < config.still_mps else -1.5 if speed < config.stop_fast_mps else -5.0
    stop += 0.0 if abs(vrate) <= 0.3 else -2.0

    lift = 0.0 if 1.0 <= speed <= config.lift_max_mps else -2.0 if speed < 1.0 else -4.0
    lift += 0.0 if vrate > config.lift_vrate_mps else -1.5 if vrate >= -0.1 else -5.0
    lift += 0.0 if frame.heading_var[i] <= config.lift_heading_var_max else -1.0

    return [descent, stop, lift, _IMPOSSIBLE]


def _viterbi(frame: FeatureFrame, lo: int, hi: int, config: AnalyzerConfig) -> list[State]:
    transitions = [
        [0.0, config.switch_descent_stop, config.switch_descent_lift, 0.0],
        [config.switch_stop_descent, 0.0, config.switch_stop_lift, 0.0],
        [config.switch_lift_descent, config.switch_lift_stop, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
    ]
    score = _emissions(frame, lo, config)
    back: list[list[int]] = []
    for i in range(lo + 1, hi + 1):
        emit = _emissions(frame, i, config)
        new_score: list[float] = []
        pointers: list[int] = []
        for j in range(_DECODED_STATES):
            best_value, best_state = score[0] + transitions[0][j], 0
            for k in range(1, _DECODED_STATES):
                value = score[k] + transitions[k][j]
                if value > best_value:
                    best_value, best_state = value, k
            new_score.append(best_value + emit[j])
            pointers.append(best_state)
        score = new_score
        back.append(pointers)
    path = [max(range(_DECODED_STATES), key=lambda j: score[j])]
    for pointers in reversed(back):
        path.append(pointers[path[-1]])
    path.reverse()
    return [State(s) for s in path]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/unit/analysis/test_hmm.py -q`
Expected: 7 passed. If `test_slow_straight_climb_is_a_fallback_lift` fails, print `frame.vrate[100]` and `frame.speed[100]`; the helper climbs at 0.5 m/s, which must exceed `lift_vrate_mps` (0.15). Do not loosen the assertion.

- [ ] **Step 5: Gates and commit**

```bash
ruff check app/services/analysis/hmm.py tests/unit/analysis && ruff format --check app/services/analysis tests/unit/analysis && mypy app/services/analysis
git add app/services/analysis/hmm.py tests/unit/analysis/test_hmm.py
git commit -m "feat(backend): Viterbi state decoding between anchored lifts"
```

---

### Task 5: Action building, masking, and break stats

**Files:**
- Create: `backend/app/services/analysis/actions.py`
- Test: `backend/tests/unit/analysis/test_actions.py`

**Interfaces:**
- Consumes: `FeatureFrame`, `State`, `LiftSpan`, `OverrideSpan`, `ActionRecord`, `SessionMetadataInput`, `SessionSummaryFields`, `AnalyzerConfig`.
- Produces: `BreakStats(count: int, duration_s: float)`; `build(frame, states, anchored, overrides, config, *, area) -> tuple[list[ActionRecord], BreakStats]` where `area` is the `resort_area` tuple or None; `break_stats(states, lo, hi, config) -> BreakStats` counting `State.STOP` stretches of at least `long_stop_s` inside `[lo, hi]`; `summarize(actions, metadata, breaks) -> SessionSummaryFields`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/unit/analysis/test_actions.py
import pytest

from app.services.analysis.actions import build
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.hmm import decode
from app.services.analysis.signal import condition
from app.services.analysis.types import OverrideSpan
from tests.unit.analysis.helpers import BASE_TIME
from tests.unit.analysis.helpers import climb
from tests.unit.analysis.helpers import descent
from tests.unit.analysis.helpers import point
from tests.unit.analysis.helpers import standstill

CONFIG = AnalyzerConfig()


def _analyze(points, overrides=(), area=None):
    frame = condition(points, CONFIG)
    assert frame is not None
    states = decode(frame, [], CONFIG)
    return build(frame, states, [], list(overrides), CONFIG, area=area)


def _runs(actions):
    return [a for a in actions if a.action_type == "run"]


def _lifts(actions):
    return [a for a in actions if a.action_type == "lift"]


def test_short_stop_between_descents_stays_inside_one_run() -> None:
    points = descent(0, 60) + standstill(60, 40, north=-472.0, alt=823.0) + descent(100, 60, north0=-472.0, alt0=823.0)
    actions, breaks = _analyze(points)
    assert len(_runs(actions)) == 1
    assert _runs(actions)[0].duration_s == pytest.approx(159, abs=3)
    assert breaks.count == 0


def test_long_stop_between_descents_is_masked_and_counted_as_a_break() -> None:
    points = descent(0, 60) + standstill(60, 300, north=-472.0, alt=823.0) + descent(360, 60, north0=-472.0, alt0=823.0)
    actions, breaks = _analyze(points)
    runs = _runs(actions)
    assert len(runs) == 1
    assert (runs[0].ended_at - runs[0].started_at).total_seconds() == pytest.approx(419, abs=3)
    assert runs[0].duration_s == pytest.approx(120, abs=12)
    assert runs[0].avg_speed_mps > 6.0
    assert breaks.count == 1
    assert breaks.duration_s == pytest.approx(300, abs=12)


def test_stop_followed_by_a_lift_ends_the_run_at_the_stop() -> None:
    points = (descent(0, 60) + standstill(60, 200, north=-472.0, alt=823.0)
              + climb(260, 200, north0=-472.0, alt0=823.0))
    actions, breaks = _analyze(points)
    runs, lifts = _runs(actions), _lifts(actions)
    assert len(runs) == 1 and len(lifts) == 1
    assert (runs[0].ended_at - BASE_TIME).total_seconds() == pytest.approx(60, abs=6)
    assert (lifts[0].started_at - BASE_TIME).total_seconds() == pytest.approx(260, abs=8)
    assert breaks.count == 1


def test_flat_shuffle_after_a_pause_at_the_bottom_is_trimmed() -> None:
    # Flat movement that continues straight out of the descent is a legitimate run-out and
    # stays in the run. Flat movement after a pause at the bottom is a separate span and is
    # trimmed from the tail.
    pause = standstill(100, 30, north=-792.0, alt=703.0)
    shuffle = [point(130 + i, north_m=-792.0 - 3.0 * i, altitude_m=703.0, speed_mps=3.0) for i in range(60)]
    points = descent(0, 100) + pause + shuffle
    runs = _runs(_analyze(points)[0])
    assert len(runs) == 1
    assert (runs[0].ended_at - BASE_TIME).total_seconds() == pytest.approx(100, abs=8)


def test_slow_traverse_before_the_first_descent_starts_the_run() -> None:
    traverse = [point(i, north_m=-3.0 * i, altitude_m=1000.0 - 0.1 * i, speed_mps=3.0) for i in range(60)]
    points = traverse + descent(60, 100, north0=-180.0, alt0=994.0)
    runs = _runs(_analyze(points)[0])
    assert len(runs) == 1
    assert (runs[0].started_at - BASE_TIME).total_seconds() <= 12


def test_vehicle_speed_is_never_a_run() -> None:
    drive = [point(i, north_m=-32.0 * i, altitude_m=1000.0 - 2.0 * i, speed_mps=32.0) for i in range(120)]
    assert _runs(_analyze(drive)[0]) == []


def test_fast_flat_travel_is_never_a_run() -> None:
    zipline = [point(i, north_m=-14.0 * i, altitude_m=1100.0, speed_mps=14.0) for i in range(60)]
    assert _runs(_analyze(zipline)[0]) == []


def test_descent_outside_the_resort_area_is_not_a_run() -> None:
    area = (48.0, 48.1, -120.0, -119.9)
    assert _runs(_analyze(descent(0, 100), area=area)[0]) == []


def test_tiny_descent_is_dropped() -> None:
    assert _runs(_analyze(descent(0, 15, speed=1.2, drop_per_s=0.4))[0]) == []


def test_lift_stoppage_merges_two_climbs_into_one_lift() -> None:
    points = (climb(0, 120) + standstill(120, 90, north=480.0, alt=880.0)
              + climb(210, 120, north0=480.0, alt0=880.0))
    assert len(_lifts(_analyze(points)[0])) == 1


def test_ignore_override_masks_stats_without_splitting() -> None:
    points = descent(0, 90)
    override = OverrideSpan(started_at=points[30].recorded_at, ended_at=points[49].recorded_at,
                            motion_state="ignore", created_by="user")
    runs = _runs(_analyze(points, overrides=[override])[0])
    assert len(runs) == 1
    assert runs[0].duration_s == pytest.approx(69, abs=3)


def test_lift_override_inside_a_descent_splits_it() -> None:
    points = descent(0, 150)
    override = OverrideSpan(started_at=points[60].recorded_at, ended_at=points[89].recorded_at,
                            motion_state="lift", created_by="user")
    actions, _ = _analyze(points, overrides=[override])
    assert len(_runs(actions)) == 2
    assert len(_lifts(actions)) == 1


def test_top_speed_ignores_a_one_sample_spike() -> None:
    points = descent(0, 90, speed=10.0)
    spike = points[45]
    points[45] = point(45, north_m=-450.0, altitude_m=865.0, speed_mps=50.0)
    run = _runs(_analyze(points)[0])[0]
    assert run.max_speed_mps == pytest.approx(10.0, abs=0.1)
    assert run.top_speed_lat != pytest.approx(spike.latitude, abs=1e-9) or run.max_speed_mps < 11.0


def test_sequence_indices_count_runs_and_lifts_separately() -> None:
    points = (descent(0, 60) + standstill(60, 30, north=-472.0, alt=823.0)
              + climb(90, 200, north0=-472.0, alt0=823.0)
              + standstill(290, 30, north=328.0, alt=1123.0)
              + descent(320, 60, north0=328.0, alt0=1123.0))
    actions, _ = _analyze(points)
    assert [a.sequence_index for a in _runs(actions)] == [1, 2]
    assert [a.sequence_index for a in _lifts(actions)] == [1]
    assert [a.action_type for a in actions] == ["run", "lift", "run"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis/test_actions.py -q`
Expected: `ModuleNotFoundError: No module named 'app.services.analysis.actions'`.

- [ ] **Step 3: Implement `actions.py`**

```python
"""Turn decoded per-second states into run and lift actions (spec section 8)."""

from __future__ import annotations

from collections.abc import Iterable
from collections.abc import Sequence
from dataclasses import dataclass

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import haversine_m
from app.services.analysis.hmm import State
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import FeatureFrame
from app.services.analysis.types import IGNORE
from app.services.analysis.types import LIFT
from app.services.analysis.types import LIVE_SOURCE
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import SessionMetadataInput
from app.services.analysis.types import SessionSummaryFields

Area = tuple[float, float, float, float]
Span = tuple[State, int, int]


@dataclass(frozen=True)
class BreakStats:
    count: int
    duration_s: float


def build(
    frame: FeatureFrame,
    states: Sequence[State],
    anchored: Sequence[LiftSpan],
    overrides: Sequence[OverrideSpan],
    config: AnalyzerConfig,
    *,
    area: Area | None,
) -> tuple[list[ActionRecord], BreakStats]:
    n = len(frame)
    st = list(states)
    locked = [False] * n
    masked = [False] * n
    for span in anchored:
        for i in range(max(0, span.start), min(n - 1, span.end) + 1):
            locked[i] = True
    _apply_overrides(frame, st, locked, masked, overrides)
    _demote_tiny_descents(frame, st, locked, config)
    _demote_weak_fallback_lifts(frame, st, locked, area, config)
    _merge_lift_stoppages(frame, st, config)

    lifts = [(a, b) for state, a, b in _spans(st) if state == State.LIFT]
    _invalidate_descents(frame, st, locked, lifts, area, config)
    runs = _assemble_runs(frame, st, config)

    for run_start, run_end in runs:
        for state, a, b in _spans(st[run_start : run_end + 1]):
            if state == State.STOP and (b - a + 1) >= config.long_stop_s:
                for i in range(run_start + a, run_start + b + 1):
                    masked[i] = True

    timeline = sorted([(a, b, RUN) for a, b in runs] + [(a, b, LIFT) for a, b in lifts])
    actions: list[ActionRecord] = []
    counters = {RUN: 0, LIFT: 0}
    for a, b, kind in timeline:
        if (b - a) < config.min_action_duration_s:
            continue
        counters[kind] += 1
        name, track_id = _lift_identity(anchored, a, b) if kind == LIFT else (None, None)
        actions.append(_record(frame, a, b, kind, counters[kind], masked, config, name, track_id))

    if not timeline:
        return actions, BreakStats(0, 0.0)
    return actions, break_stats(st, timeline[0][0], timeline[-1][1], config)


def break_stats(states: Sequence[State], lo: int, hi: int, config: AnalyzerConfig) -> BreakStats:
    count = 0
    total = 0.0
    lo = max(0, lo)
    hi = min(len(states) - 1, hi)
    for state, a, b in _spans(list(states[lo : hi + 1])):
        duration = b - a + 1
        if state == State.STOP and duration >= config.long_stop_s:
            count += 1
            total += float(duration)
    return BreakStats(count, total)


def summarize(
    actions: Sequence[ActionRecord], metadata: SessionMetadataInput, breaks: BreakStats
) -> SessionSummaryFields:
    runs = [a for a in actions if a.action_type == RUN]
    lifts = [a for a in actions if a.action_type == LIFT]
    peaks = [a.max_altitude_m for a in actions if a.max_altitude_m is not None]
    center_lat, center_long = _bbox_center(actions)
    return SessionSummaryFields(
        total_duration_s=(metadata.record_end - metadata.record_start).total_seconds(),
        descent_duration_s=sum(a.duration_s for a in runs),
        lift_duration_s=sum(a.duration_s for a in lifts),
        descent_distance_m=sum(a.distance_m for a in runs),
        lift_distance_m=sum(a.distance_m for a in lifts),
        descent_vertical_m=sum((a.vertical_m or 0.0) for a in runs),
        lift_vertical_m=sum((a.vertical_m or 0.0) for a in lifts),
        max_speed_mps=max((a.max_speed_mps for a in runs), default=None),
        avg_descent_speed_mps=(sum(a.avg_speed_mps for a in runs) / len(runs)) if runs else None,
        peak_altitude_m=max(peaks) if peaks else None,
        center_lat=center_lat,
        center_long=center_long,
        altitude_offset_m=0.0,
        break_count=breaks.count,
        break_duration_s=breaks.duration_s,
    )


# --------------------------------------------------------------------------- helpers


def _spans(states: Sequence[State]) -> list[Span]:
    out: list[Span] = []
    start = 0
    for i in range(1, len(states) + 1):
        if i == len(states) or states[i] != states[start]:
            out.append((states[start], start, i - 1))
            start = i
    return out if states else []


def _apply_overrides(
    frame: FeatureFrame,
    st: list[State],
    locked: list[bool],
    masked: list[bool],
    overrides: Sequence[OverrideSpan],
) -> None:
    for span in overrides:
        lo, hi = frame.index_at(span.started_at), frame.index_at(span.ended_at)
        for i in range(lo, hi + 1):
            if span.motion_state == IGNORE:
                masked[i] = True
            else:
                st[i] = State.LIFT if span.motion_state == LIFT else State.DESCENT
                locked[i] = True
                masked[i] = False


def _demote_tiny_descents(
    frame: FeatureFrame, st: list[State], locked: Sequence[bool], config: AnalyzerConfig
) -> None:
    for state, a, b in _spans(st):
        if state != State.DESCENT or all(locked[a : b + 1]):
            continue
        if sum(frame.speed[a : b + 1]) < config.tiny_descent_m:
            st[a : b + 1] = [State.STOP] * (b - a + 1)


def _inside_area(frame: FeatureFrame, a: int, b: int, area: Area | None) -> bool:
    if area is None:
        return True
    min_lat, max_lat, min_lon, max_lon = area
    inside = sum(
        1 for i in range(a, b + 1) if min_lat <= frame.lat[i] <= max_lat and min_lon <= frame.lon[i] <= max_lon
    )
    return inside >= 0.5 * (b - a + 1)


def _demote_weak_fallback_lifts(
    frame: FeatureFrame,
    st: list[State],
    locked: Sequence[bool],
    area: Area | None,
    config: AnalyzerConfig,
) -> None:
    n = len(st)
    i = 0
    while i < n:
        if st[i] != State.LIFT or locked[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and st[j + 1] == State.LIFT and not locked[j + 1]:
            j += 1
        speeds = sorted(frame.speed[i : j + 1])
        keep = (
            (j - i + 1) >= config.fallback_lift_min_s
            and (frame.alt[j] - frame.alt[i]) >= config.fallback_lift_min_gain_m
            and speeds[len(speeds) // 2] <= config.fallback_lift_max_median_mps
            and _inside_area(frame, i, j, area)
        )
        if not keep:
            st[i : j + 1] = [State.STOP] * (j - i + 1)
        i = j + 1


def _merge_lift_stoppages(frame: FeatureFrame, st: list[State], config: AnalyzerConfig) -> None:
    changed = True
    while changed:
        changed = False
        spans = _spans(st)
        for q in range(1, len(spans) - 1):
            state, a, b = spans[q]
            if state not in (State.STOP, State.UNKNOWN):
                continue
            if spans[q - 1][0] != State.LIFT or spans[q + 1][0] != State.LIFT:
                continue
            moved = haversine_m(frame.lat[a], frame.lon[a], frame.lat[b], frame.lon[b])
            if (b - a + 1) <= config.lift_stoppage_max_s and moved <= config.lift_stoppage_max_move_m:
                st[a : b + 1] = [State.LIFT] * (b - a + 1)
                changed = True
                break


def _invalidate_descents(
    frame: FeatureFrame,
    st: list[State],
    locked: Sequence[bool],
    lifts: Sequence[tuple[int, int]],
    area: Area | None,
    config: AnalyzerConfig,
) -> None:
    # Only lifts ridden uphill define a base. After a gondola download the rider is in the
    # valley, which is still below every uphill base, so the drive home is caught as well.
    base_alt = min((frame.alt[a] for a, b in lifts if frame.alt[b] > frame.alt[a]), default=None)
    for state, a, b in _spans(st):
        if state != State.DESCENT or all(locked[a : b + 1]):
            continue
        duration = b - a + 1
        fast_seconds = sum(1 for v in frame.speed[a : b + 1] if v > config.vehicle_mps)
        mean_speed = sum(frame.speed[a : b + 1]) / duration
        flat_fast = (
            abs(frame.alt[b] - frame.alt[a]) < config.flat_fast_max_change_m
            and mean_speed > config.flat_fast_mps
            and duration >= config.flat_fast_min_s
        )
        below_base = base_alt is not None and frame.alt[a] < base_alt + config.base_margin_m
        if (
            fast_seconds >= config.vehicle_min_s
            or flat_fast
            or below_base
            or not _inside_area(frame, a, b, area)
        ):
            st[a : b + 1] = [State.INVALID] * duration


def _assemble_runs(frame: FeatureFrame, st: Sequence[State], config: AnalyzerConfig) -> list[tuple[int, int]]:
    spans = _spans(st)
    moving = (State.DESCENT, State.INVALID)
    runs: list[tuple[int, int]] = []
    i = 0
    while i < len(spans):
        if spans[i][0] not in moving:
            i += 1
            continue
        chain = [i]
        j = i + 1
        while j < len(spans):
            state, a, b = spans[j]
            if state in moving:
                chain.append(j)
                j += 1
                continue
            bridgeable = state in (State.STOP, State.UNKNOWN) and j + 1 < len(spans) and spans[j + 1][0] in moving
            too_long = (state == State.UNKNOWN and (b - a + 1) > config.unknown_split_s) or (
                state == State.STOP and (b - a + 1) > config.max_in_run_break_s
            )
            if not bridgeable or too_long:
                break
            j += 1
        next_i = max(j, i + 1)

        def drop(index: int) -> float:
            _, a, b = spans[index]
            return frame.alt[a] - frame.alt[b]

        while chain and spans[chain[0]][0] == State.INVALID:
            chain.pop(0)
        while chain and (spans[chain[-1]][0] == State.INVALID or drop(chain[-1]) < config.tail_min_drop_m):
            chain.pop()
        if chain:
            start, end = spans[chain[0]][1], spans[chain[-1]][2]
            if (end - start + 1) >= config.min_run_s and (frame.alt[start] - frame.alt[end]) >= config.min_run_drop_m:
                runs.append((start, end))
        i = next_i
    return runs


def _lift_identity(anchored: Sequence[LiftSpan], a: int, b: int) -> tuple[str | None, str | None]:
    best: LiftSpan | None = None
    best_overlap = 0
    for span in anchored:
        overlap = min(b, span.end) - max(a, span.start) + 1
        if overlap > best_overlap:
            best, best_overlap = span, overlap
    return (best.lift_name, best.external_track_id) if best is not None else (None, None)


def _record(
    frame: FeatureFrame,
    a: int,
    b: int,
    kind: str,
    sequence_index: int,
    masked: Sequence[bool],
    config: AnalyzerConfig,
    lift_name: str | None,
    track_id: str | None,
) -> ActionRecord:
    seconds = [i for i in range(a, b + 1) if not masked[i]] or list(range(a, b + 1))
    masked_count = (b - a + 1) - len(seconds) if any(masked[a : b + 1]) else 0
    distance = sum(
        haversine_m(frame.lat[i], frame.lon[i], frame.lat[i + 1], frame.lon[i + 1])
        for i in seconds
        if i + 1 <= b and not masked[i + 1]
    )
    speeds = [frame.speed[i] for i in seconds]
    altitudes = [frame.alt[i] for i in seconds]
    lats = [frame.lat[i] for i in seconds]
    lons = [frame.lon[i] for i in seconds]

    top_speed = 0.0
    top_point = None
    allowed = set(seconds)
    for p in frame.points:
        second = frame.index_at(p.recorded_at)
        if second not in allowed or p.speed_mps is None:
            continue
        reference = max(frame.speed[second], config.spike_floor_mps)
        if p.speed_mps <= reference * config.spike_ratio and p.speed_mps > top_speed:
            top_speed, top_point = float(p.speed_mps), p

    return ActionRecord(
        action_type=kind,
        sequence_index=sequence_index,
        started_at=frame.time_at(a),
        ended_at=frame.time_at(b),
        duration_s=float(max(0, (b - a) - masked_count)),
        distance_m=distance,
        avg_speed_mps=sum(speeds) / len(speeds),
        max_speed_mps=top_speed,
        min_speed_mps=min(speeds),
        vertical_m=max(altitudes) - min(altitudes),
        min_altitude_m=min(altitudes),
        max_altitude_m=max(altitudes),
        min_lat=min(lats),
        max_lat=max(lats),
        min_long=min(lons),
        max_long=max(lons),
        top_speed_lat=top_point.latitude if top_point is not None else None,
        top_speed_long=top_point.longitude if top_point is not None else None,
        top_speed_alt_m=top_point.altitude_m if top_point is not None else None,
        time_of_day=None,
        external_track_id=track_id,
        source=LIVE_SOURCE,
        lift_name=lift_name,
    )


def _bbox_center(actions: Iterable[ActionRecord]) -> tuple[float | None, float | None]:
    lats: list[float] = []
    longs: list[float] = []
    for action in actions:
        lats.extend(v for v in (action.min_lat, action.max_lat) if v is not None)
        longs.extend(v for v in (action.min_long, action.max_long) if v is not None)
    if not lats or not longs:
        return None, None
    return (min(lats) + max(lats)) / 2.0, (min(longs) + max(longs)) / 2.0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/unit/analysis/test_actions.py -q`
Expected: 14 passed. When one fails, print the decoded spans with `[(s.name, a, b) for s, a, b in actions._spans(states)]` before changing anything; fix the code, not the expectation. The only values you may adjust in a test are its `abs=` tolerances, by at most 5 s, with the reason in the report.

- [ ] **Step 5: Gates and commit**

```bash
ruff check app/services/analysis/actions.py tests/unit/analysis && ruff format --check app/services/analysis tests/unit/analysis && mypy app/services/analysis
git add app/services/analysis/actions.py tests/unit/analysis/test_actions.py
git commit -m "feat(backend): context-aware run assembly, break masking, and break stats"
```

---

### Task 6: Orchestration and the shim

**Files:**
- Create: `backend/app/services/analysis/analyzer.py`
- Modify: `backend/app/services/analysis/__init__.py` (export `SessionAnalyzer`, `smooth_speeds_centered_mean`), `backend/app/services/session_analyzer.py` (becomes a shim), `backend/tests/unit/test_session_analyzer.py` (live-path tests rewritten)
- Test: `backend/tests/unit/analysis/test_analyzer.py`

**Interfaces:**
- Consumes: everything from Tasks 1 to 5.
- Produces: `SessionAnalyzer(*, analyzer_version: str, config: AnalyzerConfig | None = None)` with `analyze(analyzer_input: AnalyzerInput) -> AnalysisResult`. `app.services.session_analyzer` re-exports the same public names as before plus `AnalyzerConfig`; `LIFT_MATCH_RADIUS_M`, `MAX_MID_ACTION_IGNORE_S`, and `MIN_ACTION_DURATION_S` are no longer exported (grep confirms nothing imports them).

- [ ] **Step 1: Write the failing orchestration tests**

```python
# backend/tests/unit/analysis/test_analyzer.py
import pytest

from app.services.analysis import AnalyzerInput
from app.services.analysis import PresetAction
from app.services.analysis import ResortLift
from app.services.analysis import SessionAnalyzer
from app.services.analysis import SessionMetadataInput
from app.services.exceptions import ValidationError
from tests.unit.analysis.helpers import DEG_LAT_PER_M
from tests.unit.analysis.helpers import climb
from tests.unit.analysis.helpers import descent
from tests.unit.analysis.helpers import standstill


def _input(points, **kwargs) -> AnalyzerInput:
    metadata = SessionMetadataInput(
        record_start=points[0].recorded_at, record_end=points[-1].recorded_at, resort_id=None, source="live_recording"
    )
    return AnalyzerInput(points=points, metadata=metadata, **kwargs)


def test_live_path_produces_run_lift_run_with_summary_and_breaks() -> None:
    points = (descent(0, 90) + standstill(90, 150, north=-712.0, alt=733.0)
              + climb(240, 200, north0=-712.0, alt0=733.0)
              + standstill(440, 20, north=88.0, alt=1033.0)
              + descent(460, 90, north0=88.0, alt0=1033.0))
    result = SessionAnalyzer(analyzer_version="analyzer@test").analyze(_input(points))
    assert [a.action_type for a in result.actions] == ["run", "lift", "run"]
    assert result.summary.break_count == 1
    assert result.summary.break_duration_s == pytest.approx(150, abs=12)
    assert result.summary.descent_vertical_m == pytest.approx(534, abs=30)
    assert result.analyzer_version == "analyzer@test"


def test_catalog_lift_gets_its_name() -> None:
    lift = ResortLift(name="Test Chair", polyline=((49.4, -123.0), (49.4 + 800 * DEG_LAT_PER_M, -123.0)),
                      lift_type="chair", osm_aerialway="chair_lift", external_track_id="osm:way:1")
    result = SessionAnalyzer(analyzer_version="v").analyze(_input(climb(0, 190), resort_lifts=(lift,)))
    lifts = [a for a in result.actions if a.action_type == "lift"]
    assert len(lifts) == 1
    assert lifts[0].lift_name == "Test Chair"
    assert lifts[0].external_track_id == "osm:way:1"


def test_no_points_and_no_presets_yields_an_empty_result() -> None:
    points = descent(0, 2)
    empty = AnalyzerInput(points=[], metadata=_input(points).metadata)
    result = SessionAnalyzer(analyzer_version="v").analyze(empty)
    assert result.actions == []
    assert result.summary.break_count == 0


def test_preset_actions_win_but_breaks_come_from_the_points() -> None:
    points = descent(0, 60) + standstill(60, 300, north=-472.0, alt=823.0) + descent(360, 60, north0=-472.0, alt0=823.0)
    preset = PresetAction(action_type="run", sequence_index=1, started_at=points[0].recorded_at,
                          ended_at=points[-1].recorded_at, duration_s=419.0, distance_m=900.0,
                          avg_speed_mps=2.1, max_speed_mps=9.0)
    result = SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_actions=[preset]))
    assert len(result.actions) == 1
    assert result.actions[0].source == "slopes_import"
    assert result.actions[0].duration_s == 419.0
    assert result.summary.break_count == 1


def test_invalid_preset_type_is_rejected() -> None:
    points = descent(0, 5)
    bad = PresetAction(action_type="walk", sequence_index=1, started_at=points[0].recorded_at,
                       ended_at=points[-1].recorded_at, duration_s=4.0, distance_m=1.0,
                       avg_speed_mps=1.0, max_speed_mps=1.0)
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_actions=[bad]))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/unit/analysis/test_analyzer.py -q`
Expected: `ImportError: cannot import name 'SessionAnalyzer' from 'app.services.analysis'`.

- [ ] **Step 3: Implement `analyzer.py`**

Move `_validate_input`, `_actions_from_preset`, `_opt_float`, and `_override_to_record` verbatim from `session_analyzer.py` (they reference `RUN`, `LIFT`, `IGNORE`, `_IMPORT_SOURCE`; import `IMPORT_SOURCE` and use it in place of `_IMPORT_SOURCE`). The rest of the file:

```python
"""Pure session analyzer. Call `SessionAnalyzer.analyze` to get an `AnalysisResult`."""

from __future__ import annotations

from collections.abc import Sequence

from app.services.analysis.actions import BreakStats
from app.services.analysis.actions import break_stats
from app.services.analysis.actions import build
from app.services.analysis.actions import summarize
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.hmm import decode
from app.services.analysis.lift_matching import anchor
from app.services.analysis.lift_matching import resort_area
from app.services.analysis.signal import condition
from app.services.analysis.types import IGNORE
from app.services.analysis.types import IMPORT_SOURCE
from app.services.analysis.types import LIFT
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import AnalysisResult
from app.services.analysis.types import AnalyzerInput
from app.services.analysis.types import OverrideRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import PresetAction
from app.services.exceptions import ValidationError


class SessionAnalyzer:
    """`analyzer_version` and `config` are injected; the analyzer never reads settings."""

    def __init__(self, *, analyzer_version: str, config: AnalyzerConfig | None = None) -> None:
        self._analyzer_version = analyzer_version
        self._config = config or AnalyzerConfig()

    def analyze(self, analyzer_input: AnalyzerInput) -> AnalysisResult:
        _validate_input(analyzer_input)
        config = self._config
        overrides = list(analyzer_input.preset_overrides or ())

        frame = condition(analyzer_input.points, config) if analyzer_input.points else None
        actions: list[ActionRecord] = []
        breaks = BreakStats(0, 0.0)
        if frame is not None:
            anchored = anchor(frame, analyzer_input.resort_lifts, config)
            states = decode(frame, anchored, config)
            if analyzer_input.preset_actions:
                first = min(p.started_at for p in analyzer_input.preset_actions)
                last = max(p.ended_at for p in analyzer_input.preset_actions)
                breaks = break_stats(states, frame.index_at(first), frame.index_at(last), config)
            else:
                area = resort_area(analyzer_input.resort_lifts, config)
                actions, breaks = build(frame, states, anchored, overrides, config, area=area)
        if analyzer_input.preset_actions:
            actions = _actions_from_preset(analyzer_input.preset_actions)

        return AnalysisResult(
            summary=summarize(actions, analyzer_input.metadata, breaks),
            actions=actions,
            overrides=[_override_to_record(span) for span in overrides],
            analyzer_version=self._analyzer_version,
        )
```

- [ ] **Step 4: Replace `session_analyzer.py` with the shim**

Delete the whole old file content and write:

```python
"""Compatibility shim. The analyzer lives in `app.services.analysis`."""

from app.services.analysis import IGNORE
from app.services.analysis import LIFT
from app.services.analysis import RUN
from app.services.analysis import ActionRecord
from app.services.analysis import AnalysisResult
from app.services.analysis import AnalyzerConfig
from app.services.analysis import AnalyzerInput
from app.services.analysis import OverrideRecord
from app.services.analysis import OverrideSpan
from app.services.analysis import PresetAction
from app.services.analysis import RawPoint
from app.services.analysis import ResortLift
from app.services.analysis import SessionAnalyzer
from app.services.analysis import SessionMetadataInput
from app.services.analysis import SessionSummaryFields
from app.services.analysis import smooth_speeds_centered_mean

__all__ = [
    "IGNORE",
    "LIFT",
    "RUN",
    "ActionRecord",
    "AnalysisResult",
    "AnalyzerConfig",
    "AnalyzerInput",
    "OverrideRecord",
    "OverrideSpan",
    "PresetAction",
    "RawPoint",
    "ResortLift",
    "SessionAnalyzer",
    "SessionMetadataInput",
    "SessionSummaryFields",
    "smooth_speeds_centered_mean",
]
```

In `analysis/__init__.py` add `from app.services.analysis.analyzer import SessionAnalyzer` and `from app.services.analysis.signal import smooth_speeds_centered_mean`, and add both names to `__all__`.

- [ ] **Step 5: Rewrite the legacy live-path tests**

In `backend/tests/unit/test_session_analyzer.py` keep, unchanged: the imports, `_parse_cypress_presets`, `_base_metadata`, `_make_point`, `test_speed_smoothing_canonical_reference`, `test_cypress_fixture_import_path_totals_match_plan`, and `_build_linear_descent`. Delete every other test (they assert quirks of the old algorithm: the first sample being ignored, the 360 s absorb cap, and 15 to 30 sample runs that are now under the 20 s minimum). Their behaviours are covered by `tests/unit/analysis/`. Append these three end-to-end checks that go through the shim:

```python
def test_shim_live_path_synthetic_descent() -> None:
    base_time = datetime(2026, 2, 1, 10, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time, sample_count=90, speed_mps=10.0, altitude_drop_per_sample_m=5.0
    )
    result = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION).analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at, record_end=points[-1].recorded_at, source="live_recording"
            ),
        )
    )
    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    assert runs[0].duration_s == pytest.approx(89, abs=DURATION_ABS + 2.0)
    assert runs[0].distance_m == pytest.approx(89 * 9.99, abs=25.0)
    assert runs[0].max_speed_mps == pytest.approx(10.0, abs=SPEED_ABS)
    assert {a.action_type for a in result.actions} <= {"run", "lift"}


def test_shim_peak_altitude_ignores_a_stationary_flyaway_point() -> None:
    base_time = datetime(2026, 2, 1, 16, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time, sample_count=90, speed_mps=10.0, altitude_drop_per_sample_m=5.0,
        start_altitude_m=1200.0,
    )
    flyaway = RawPoint(
        t_offset_ms=points[-1].t_offset_ms + 300_000,
        recorded_at=points[-1].recorded_at + timedelta(seconds=300),
        latitude=points[-1].latitude,
        longitude=points[-1].longitude,
        altitude_m=4000.0,
        speed_mps=0.0,
        accuracy_m=5.0,
    )
    result = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION).analyze(
        AnalyzerInput(
            points=[*points, flyaway],
            metadata=_base_metadata(
                record_start=points[0].recorded_at, record_end=flyaway.recorded_at, source="live_recording"
            ),
        )
    )
    assert result.summary.peak_altitude_m is not None
    assert result.summary.peak_altitude_m < 1300.0


def test_shim_exports_the_config_type() -> None:
    from app.services.session_analyzer import AnalyzerConfig

    assert AnalyzerConfig().long_stop_s == 120
```

Remove the now-unused imports (`OverrideSpan`, `ResortLift`) if ruff reports them.

- [ ] **Step 6: Run the affected suites**

Run: `python -m pytest tests/unit/analysis tests/unit/test_session_analyzer.py tests/unit/test_session_service.py -q`
Expected: all pass. `test_session_service.py` uses fakes around the analyzer; if one of its tests builds fewer than 25 synthetic points and expects a run, lengthen its point list to 90 samples with the same slope and note it in the report.

- [ ] **Step 7: Gates and commit**

```bash
ruff check app/services/analysis app/services/session_analyzer.py tests/unit/analysis tests/unit/test_session_analyzer.py
ruff format --check app/services/analysis app/services/session_analyzer.py tests/unit/analysis tests/unit/test_session_analyzer.py
mypy app/services/analysis app/services/session_analyzer.py
git add -A app/services tests/unit
git commit -m "feat(backend): route SessionAnalyzer through the analysis pipeline"
```

---

### Task 7: Corpus, Overpass fixtures, and the lift mapping

**Files:**
- Create: eleven archives under `backend/tests/fixtures/slopes/`, `backend/tests/fixtures/osm/overpass_grouse.json`, `overpass_cypress.json`, `overpass_seymour.json`, `backend/app/services/osm_lift_mapping.py`
- Test: `backend/tests/unit/test_osm_lift_mapping.py`

**Interfaces:**
- Produces: `OsmLift(name: str, lift_type: str, osm_aerialway: str, polyline: tuple[tuple[float, float], ...], external_track_id: str, base_altitude_m: float | None, top_altitude_m: float | None)`; `map_overpass_ways(payload: Mapping[str, object]) -> list[OsmLift]`. Plan 2 reuses both for the database import.

- [ ] **Step 1: Copy the archives**

The three existing fixtures stay. Copy the other eleven from `../../slopes-files/` (that is `goofy-rider/slopes-files/`, one level above the git root) with this exact mapping:

```bash
cd backend/tests/fixtures/slopes
S="../../../../../slopes-files"
cp "$S/April 4 2025 - Grouse Mountain.slopes"      grouse_2025-04-04.slopes
cp "$S/April 4 2026 - Grouse Mountain.slopes"      grouse_2026-04-04.slopes
cp "$S/February 11 2026 - Grouse Mountain.slopes"  grouse_2026-02-11.slopes
cp "$S/February 12 2025 - Cypress Mountain.slopes" cypress_2025-02-12.slopes
cp "$S/February 19 2026 - Mount Seymour.slopes"    seymour_2026-02-19.slopes
cp "$S/February 28 2026 - Grouse Mountain.slopes"  grouse_2026-02-28.slopes
cp "$S/January 20 2025 - Cypress Mountain.slopes"  cypress_2025-01-20.slopes
cp "$S/January 3 2025 - Cypress Mountain.slopes"   cypress_2025-01-03.slopes
cp "$S/March 13 2026 - Grouse Mountain.slopes"     grouse_2026-03-13.slopes
cp "$S/March 2 2025 - Grouse Mountain.slopes"      grouse_2025-03-02.slopes
cp "$S/March 27 2026 - Grouse Mountain.slopes"     grouse_2026-03-27.slopes
ls *.slopes | wc -l
```
Expected: `14`. If `slopes-files` is missing, stop and report NEEDS_CONTEXT; do not fabricate archives.

- [ ] **Step 2: Copy the recorded Overpass responses**

```bash
mkdir -p backend/tests/fixtures/osm
cp .superpowers/spikes/2026-09-17-gps-segmentation/overpass_*.json backend/tests/fixtures/osm/
python -c "import json,glob;[print(f, len(json.load(open(f,encoding='utf-8'))['elements'])) for f in sorted(glob.glob('backend/tests/fixtures/osm/*.json'))]"
```
Expected: three files with 11 (cypress), 13 (grouse), and 12 (seymour) elements. If the spike folder is missing, stop and report NEEDS_CONTEXT; tests must not fetch from the network.

- [ ] **Step 3: Write the failing mapping test**

```python
# backend/tests/unit/test_osm_lift_mapping.py
import json
from pathlib import Path

from app.services.osm_lift_mapping import map_overpass_ways

_FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "osm"


def _load(name: str) -> dict[str, object]:
    return json.loads((_FIXTURES / name).read_text(encoding="utf-8"))


def test_grouse_lifts_are_mapped_and_zip_lines_skipped() -> None:
    lifts = {lift.name: lift for lift in map_overpass_ways(_load("overpass_grouse.json"))}
    assert "Screaming Eagle Chair" in lifts
    assert not any("Zip Line" in name for name in lifts)
    assert lifts["Screaming Eagle Chair"].lift_type == "chair"
    assert lifts["Red Skyride"].lift_type == "gondola"
    assert lifts["Red Skyride"].osm_aerialway == "cable_car"
    assert lifts["Magic Carpet"].lift_type == "magic_carpet"
    assert lifts["Side Cut Handle Tow"].lift_type == "surface"
    assert lifts["Peak Chair"].external_track_id.startswith("osm:way:")
    assert len(lifts["Peak Chair"].polyline) >= 2


def test_stations_are_skipped_and_unnamed_lifts_get_a_label() -> None:
    lifts = map_overpass_ways(_load("overpass_cypress.json"))
    assert all(lift.osm_aerialway != "station" for lift in lifts)
    assert any(lift.name == "Unnamed magic_carpet" for lift in lifts)


def test_malformed_elements_are_ignored() -> None:
    payload = {"elements": [{"type": "way", "id": 1, "tags": {"aerialway": "chair_lift"}, "geometry": [{"lat": 1.0, "lon": 2.0}]},
                            {"type": "node", "id": 2}, {"type": "way", "id": 3}]}
    assert map_overpass_ways(payload) == []
```

- [ ] **Step 4: Run it to verify it fails, then implement `osm_lift_mapping.py`**

Run: `python -m pytest tests/unit/test_osm_lift_mapping.py -q` (expected: `ModuleNotFoundError`).

```python
"""Pure mapping from an Overpass `out geom` payload to lift rows (spec section 3.2)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import logging

logger = logging.getLogger(__name__)

_LIFT_TYPE_BY_AERIALWAY = {
    "chair_lift": "chair",
    "gondola": "gondola",
    "cable_car": "gondola",
    "mixed_lift": "gondola",
    "drag_lift": "surface",
    "platter": "surface",
    "rope_tow": "surface",
    "j-bar": "surface",
    "t-bar": "tbar",
    "magic_carpet": "magic_carpet",
}


@dataclass(frozen=True)
class OsmLift:
    name: str
    lift_type: str
    osm_aerialway: str
    polyline: tuple[tuple[float, float], ...]
    external_track_id: str
    base_altitude_m: float | None = None
    top_altitude_m: float | None = None


def map_overpass_ways(payload: Mapping[str, object]) -> list[OsmLift]:
    elements = payload.get("elements")
    if not isinstance(elements, list):
        return []
    lifts: list[OsmLift] = []
    for element in elements:
        if not isinstance(element, dict) or element.get("type") != "way":
            continue
        tags = element.get("tags")
        geometry = element.get("geometry")
        if not isinstance(tags, dict) or not isinstance(geometry, list):
            continue
        aerialway = tags.get("aerialway")
        lift_type = _LIFT_TYPE_BY_AERIALWAY.get(aerialway) if isinstance(aerialway, str) else None
        if lift_type is None or not isinstance(aerialway, str):
            logger.info("Skipping aerialway %r (way %s)", aerialway, element.get("id"))
            continue
        polyline = tuple(
            (float(node["lat"]), float(node["lon"]))
            for node in geometry
            if isinstance(node, dict) and "lat" in node and "lon" in node
        )
        if len(polyline) < 2:
            continue
        name = tags.get("name")
        lifts.append(
            OsmLift(
                name=name if isinstance(name, str) and name.strip() else f"Unnamed {lift_type}",
                lift_type=lift_type,
                osm_aerialway=aerialway,
                polyline=polyline,
                external_track_id=f"osm:way:{element.get('id')}",
            )
        )
    return lifts
```

- [ ] **Step 5: Run the test, gates, commit**

Run: `python -m pytest tests/unit/test_osm_lift_mapping.py tests/unit/test_slopes_fixture_contract.py -q` (expected: all pass).

```bash
ruff check app/services/osm_lift_mapping.py tests/unit/test_osm_lift_mapping.py && ruff format --check app/services/osm_lift_mapping.py tests/unit/test_osm_lift_mapping.py && mypy app/services/osm_lift_mapping.py
git add backend/tests/fixtures/slopes backend/tests/fixtures/osm backend/app/services/osm_lift_mapping.py backend/tests/unit/test_osm_lift_mapping.py
git commit -m "test(backend): full Slopes corpus, recorded Overpass lifts, and OSM lift mapping"
```

---

### Task 8: Scorer script

**Files:**
- Create: `backend/app/scripts/evaluate_analyzer.py`, `backend/tests/fixtures/slopes/label_overrides.json`
- Test: `backend/tests/unit/test_evaluate_analyzer.py`

**Interfaces:**
- Consumes: `SessionAnalyzer`, `AnalyzerConfig`, `parse_overrides`, `map_overpass_ways`.
- Produces: `CORPUS_DIR`, `OSM_DIR` (paths); `load_archive(path) -> CorpusArchive` with fields `name: str`, `record_start: datetime`, `record_end: datetime`, `points: list[RawPoint]`, `labels: list[LabelledAction]` (`kind`, `started_at`, `ended_at`), already corrected by the overrides file; `score_archive(archive, analyzer, lifts) -> ArchiveScore` (`name`, `agreement`, `runs`, `ref_runs`, `lifts`, `ref_lifts`, `lift_found`, `lift_correct`, `run_found`, `run_correct`); `score_corpus(config, *, use_catalog=True) -> CorpusScore` (`archives: list[ArchiveScore]`, properties `mean_agreement`, `exact_count_archives`, `lift_recall`, `lift_precision`, `run_recall`, `run_precision`); `main(argv)`.
- Spec note: section 9.1 places the label loader in `tests/unit/slopes_labels.py`. It lives in this script module instead so the CLI and the test share one implementation. Update that sentence of the spec in this task's commit.

- [ ] **Step 1: Find the override entry and write `label_overrides.json`**

Run from `backend/`:

```bash
python - <<'EOF'
import zipfile, xml.etree.ElementTree as ET
root = ET.fromstring(zipfile.ZipFile("tests/fixtures/slopes/grouse_2026-03-13.slopes").read("Metadata.xml"))
for a in root.find("actions"):
    if a.attrib["type"] == "Lift" and float(a.attrib["duration"]) > 1200:
        print(a.attrib["start"], a.attrib["end"], a.attrib["duration"])
EOF
```
Expected: exactly one line, starting `2026-03-13 19:32:48 -0700`, a lift of about 1444 s. If the printed start differs, use the printed value and say so in the report. Create the file:

```json
[
  {
    "archive": "grouse_2026-03-13",
    "action_start": "2026-03-13 19:32:48 -0700",
    "original": "lift",
    "corrected": "other",
    "reason": "Rider walks the summit plateau at about 1.3 m/s, gaining 20 m over 24 minutes with a 12 minute pause; not a lift ride."
  }
]
```

- [ ] **Step 2: Write the failing scorer tests**

```python
# backend/tests/unit/test_evaluate_analyzer.py
from app.scripts.evaluate_analyzer import CORPUS_DIR
from app.scripts.evaluate_analyzer import load_archive
from app.scripts.evaluate_analyzer import score_archive
from app.services.analysis import AnalyzerConfig
from app.services.analysis import SessionAnalyzer


def test_corpus_has_fourteen_archives() -> None:
    assert len(sorted(CORPUS_DIR.glob("*.slopes"))) == 14


def test_archive_loads_points_with_accuracy_and_labels() -> None:
    archive = load_archive(CORPUS_DIR / "cypress_2025-01-03.slopes")
    assert len(archive.points) > 500
    assert archive.points[0].accuracy_m is not None
    assert archive.points[0].vertical_accuracy_m is not None
    assert {label.kind for label in archive.labels} == {"run", "lift"}
    assert archive.labels == sorted(archive.labels, key=lambda label: label.started_at)


def test_label_override_removes_the_plateau_walk_lift() -> None:
    archive = load_archive(CORPUS_DIR / "grouse_2026-03-13.slopes")
    durations = [(label.ended_at - label.started_at).total_seconds() for label in archive.labels if label.kind == "lift"]
    assert max(durations) < 1200


def test_scoring_the_cleanest_archive() -> None:
    archive = load_archive(CORPUS_DIR / "cypress_2025-01-03.slopes")
    analyzer = SessionAnalyzer(analyzer_version="test", config=AnalyzerConfig())
    score = score_archive(archive, analyzer, lifts=())
    assert score.ref_runs == 3 and score.ref_lifts == 3
    assert 0.0 <= score.agreement <= 1.0
    assert score.agreement > 0.9
```

- [ ] **Step 3: Run to verify failure, then implement the script**

Run: `python -m pytest tests/unit/test_evaluate_analyzer.py -q` (expected: `ModuleNotFoundError`).

```python
"""Score the session analyzer against the Slopes corpus.

Usage (from backend/):
    python -m app.scripts.evaluate_analyzer [--no-catalog] [--config key=value ...]
                                            [--write-expected] [--json PATH]
"""

from __future__ import annotations

from argparse import ArgumentParser
from collections.abc import Sequence
import csv
from dataclasses import asdict
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

from app.services.analysis import AnalyzerConfig
from app.services.analysis import AnalyzerInput
from app.services.analysis import RawPoint
from app.services.analysis import ResortLift
from app.services.analysis import SessionAnalyzer
from app.services.analysis import SessionMetadataInput
from app.services.analysis.config import parse_overrides
from app.services.osm_lift_mapping import map_overpass_ways

_BACKEND_DIR = Path(__file__).resolve().parents[2]
CORPUS_DIR = _BACKEND_DIR / "tests" / "fixtures" / "slopes"
OSM_DIR = _BACKEND_DIR / "tests" / "fixtures" / "osm"
OVERRIDES_PATH = CORPUS_DIR / "label_overrides.json"
EXPECTED_PATH = CORPUS_DIR / "expected_scores.json"
_SLOPES_DT = "%Y-%m-%d %H:%M:%S %z"
_MATCH_OVERLAP = 0.5


@dataclass(frozen=True)
class LabelledAction:
    kind: str
    started_at: datetime
    ended_at: datetime


@dataclass(frozen=True)
class CorpusArchive:
    name: str
    record_start: datetime
    record_end: datetime
    points: list[RawPoint]
    labels: list[LabelledAction]


@dataclass(frozen=True)
class ArchiveScore:
    name: str
    agreement: float
    runs: int
    ref_runs: int
    lifts: int
    ref_lifts: int
    lift_found: int
    lift_correct: int
    run_found: int
    run_correct: int

    @property
    def exact_counts(self) -> bool:
        return self.runs == self.ref_runs and self.lifts == self.ref_lifts


@dataclass(frozen=True)
class CorpusScore:
    archives: list[ArchiveScore]

    @property
    def mean_agreement(self) -> float:
        return sum(a.agreement for a in self.archives) / len(self.archives)

    @property
    def exact_count_archives(self) -> int:
        return sum(1 for a in self.archives if a.exact_counts)

    @property
    def lift_recall(self) -> float:
        return sum(a.lift_found for a in self.archives) / max(1, sum(a.ref_lifts for a in self.archives))

    @property
    def lift_precision(self) -> float:
        return sum(a.lift_correct for a in self.archives) / max(1, sum(a.lifts for a in self.archives))

    @property
    def run_recall(self) -> float:
        return sum(a.run_found for a in self.archives) / max(1, sum(a.ref_runs for a in self.archives))

    @property
    def run_precision(self) -> float:
        return sum(a.run_correct for a in self.archives) / max(1, sum(a.runs for a in self.archives))


def load_archive(path: Path) -> CorpusArchive:
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read("Metadata.xml"))
        gps_text = archive.read("GPS.csv").decode("utf-8")
    record_start = datetime.strptime(root.attrib["recordStart"], _SLOPES_DT)
    record_end = datetime.strptime(root.attrib["recordEnd"], _SLOPES_DT)
    corrections = {
        entry["action_start"]: entry["corrected"]
        for entry in json.loads(OVERRIDES_PATH.read_text(encoding="utf-8"))
        if entry["archive"] == path.stem
    }
    labels: list[LabelledAction] = []
    actions_root = root.find("actions")
    for action in actions_root if actions_root is not None else []:
        kind = corrections.get(action.attrib["start"], action.attrib["type"].lower())
        if kind not in ("run", "lift"):
            continue
        labels.append(
            LabelledAction(
                kind=kind,
                started_at=datetime.strptime(action.attrib["start"], _SLOPES_DT),
                ended_at=datetime.strptime(action.attrib["end"], _SLOPES_DT),
            )
        )
    labels.sort(key=lambda label: label.started_at)

    points: list[RawPoint] = []
    start_epoch, end_epoch = record_start.timestamp(), record_end.timestamp()
    for row in csv.reader(io.StringIO(gps_text)):
        if len(row) < 8:
            continue
        epoch = float(row[0])
        if epoch < start_epoch - 1 or epoch > end_epoch + 1:
            continue
        points.append(
            RawPoint(
                t_offset_ms=max(0, round((epoch - start_epoch) * 1000)),
                recorded_at=datetime.fromtimestamp(epoch, tz=UTC),
                latitude=float(row[1]),
                longitude=float(row[2]),
                altitude_m=float(row[3]),
                speed_mps=max(0.0, float(row[5])),
                accuracy_m=float(row[6]),
                vertical_accuracy_m=float(row[7]),
                heading_deg=float(row[4]) if float(row[4]) >= 0 else None,
            )
        )
    return CorpusArchive(path.stem, record_start, record_end, points, labels)


def lifts_for(archive_name: str) -> tuple[ResortLift, ...]:
    resort = archive_name.split("_", 1)[0]
    path = OSM_DIR / f"overpass_{resort}.json"
    if not path.exists():
        return ()
    payload = json.loads(path.read_text(encoding="utf-8"))
    return tuple(
        ResortLift(
            name=lift.name,
            polyline=lift.polyline,
            lift_type=lift.lift_type,
            osm_aerialway=lift.osm_aerialway,
            external_track_id=lift.external_track_id,
        )
        for lift in map_overpass_ways(payload)
    )


def score_archive(
    archive: CorpusArchive, analyzer: SessionAnalyzer, lifts: Sequence[ResortLift]
) -> ArchiveScore:
    result = analyzer.analyze(
        AnalyzerInput(
            points=archive.points,
            metadata=SessionMetadataInput(
                record_start=archive.record_start,
                record_end=archive.record_end,
                resort_id=None,
                source="live_recording",
            ),
            resort_lifts=tuple(lifts),
        )
    )
    origin = int(archive.points[0].recorded_at.timestamp())
    seconds = int(archive.points[-1].recorded_at.timestamp()) - origin + 1

    def to_spans(items: Sequence[tuple[str, datetime, datetime]], kind: str) -> list[tuple[int, int]]:
        return [
            (max(0, int(s.timestamp()) - origin), min(seconds - 1, int(e.timestamp()) - origin))
            for k, s, e in items
            if k == kind
        ]

    ours = [(a.action_type, a.started_at, a.ended_at) for a in result.actions]
    theirs = [(label.kind, label.started_at, label.ended_at) for label in archive.labels]
    spans = {(who, kind): to_spans(items, kind) for who, items in (("ours", ours), ("ref", theirs)) for kind in ("run", "lift")}

    def paint(who: str) -> list[str]:
        track = ["other"] * seconds
        for kind in ("run", "lift"):
            for a, b in spans[(who, kind)]:
                for i in range(a, b + 1):
                    track[i] = kind
        return track

    mine, reference = paint("ours"), paint("ref")
    agreement = sum(1 for x, y in zip(mine, reference, strict=True) if x == y) / seconds

    def matches(targets: Sequence[tuple[int, int]], pool: Sequence[tuple[int, int]]) -> int:
        hits = 0
        for a, b in targets:
            best = max((min(b, y) - max(a, x) + 1 for x, y in pool), default=0)
            if best >= _MATCH_OVERLAP * (b - a + 1):
                hits += 1
        return hits

    return ArchiveScore(
        name=archive.name,
        agreement=agreement,
        runs=len(spans[("ours", "run")]),
        ref_runs=len(spans[("ref", "run")]),
        lifts=len(spans[("ours", "lift")]),
        ref_lifts=len(spans[("ref", "lift")]),
        lift_found=matches(spans[("ref", "lift")], spans[("ours", "lift")]),
        lift_correct=matches(spans[("ours", "lift")], spans[("ref", "lift")]),
        run_found=matches(spans[("ref", "run")], spans[("ours", "run")]),
        run_correct=matches(spans[("ours", "run")], spans[("ref", "run")]),
    )


def score_corpus(config: AnalyzerConfig, *, use_catalog: bool = True) -> CorpusScore:
    analyzer = SessionAnalyzer(analyzer_version="evaluation", config=config)
    scores = []
    for path in sorted(CORPUS_DIR.glob("*.slopes")):
        archive = load_archive(path)
        scores.append(score_archive(archive, analyzer, lifts_for(archive.name) if use_catalog else ()))
    return CorpusScore(scores)


def main(argv: Sequence[str] | None = None) -> int:
    parser = ArgumentParser(description="Score the session analyzer against the Slopes corpus.")
    parser.add_argument("--no-catalog", action="store_true")
    parser.add_argument("--config", nargs="*", default=[], metavar="key=value")
    parser.add_argument("--write-expected", action="store_true")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args(argv)

    config = AnalyzerConfig().with_overrides(**parse_overrides(args.config))
    corpus = score_corpus(config, use_catalog=not args.no_catalog)
    for a in corpus.archives:
        flag = "OK" if a.exact_counts else "  "
        print(f"{a.name:24s} agree {a.agreement * 100:5.1f}%  runs {a.runs:2d}/{a.ref_runs:2d}  lifts {a.lifts:2d}/{a.ref_lifts:2d} {flag}")
    print(
        f"MEAN {corpus.mean_agreement * 100:.1f}%  exact {corpus.exact_count_archives}/{len(corpus.archives)}  "
        f"lift R {corpus.lift_recall * 100:.1f}% P {corpus.lift_precision * 100:.1f}%  "
        f"run R {corpus.run_recall * 100:.1f}% P {corpus.run_precision * 100:.1f}%"
    )
    payload = {a.name: asdict(a) for a in corpus.archives}
    if args.json is not None:
        args.json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    if args.write_expected:
        EXPECTED_PATH.write_text(
            json.dumps({n: {"agreement": round(v["agreement"], 4), "runs": v["runs"], "lifts": v["lifts"]} for n, v in payload.items()}, indent=2) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the tests and the script**

Run: `python -m pytest tests/unit/test_evaluate_analyzer.py -q` (expected: 4 passed), then `python -m app.scripts.evaluate_analyzer` and `python -m app.scripts.evaluate_analyzer --no-catalog`. Paste both tables into the task report. This plan's code was dry-run before the plan was committed, so with the defaults of Task 1 you should see, within a few tenths: with the catalog `MEAN 86.1%  exact 7/14  lift R 94.9% P 93.0%  run R 87.0% P 93.5%`, and without it `MEAN 84.0%  exact 6/14  lift R 86.3% P 100.0%  run R 92.2% P 87.2%`. A result more than one point below that means a transcription error in Tasks 2 to 6; find it before continuing.

- [ ] **Step 5: Gates and commit**

In the spec, replace the sentence in section 9.1 that starts "`tests/unit/slopes_labels.py` turns" with: "`app/scripts/evaluate_analyzer.py` (`load_archive`) turns each archive's Run and Lift actions, corrected by `label_overrides.json`, into labelled spans that are painted per second as `run`, `lift`, or `other` over the recording window."

```bash
ruff check app/scripts/evaluate_analyzer.py tests/unit/test_evaluate_analyzer.py && ruff format --check app/scripts/evaluate_analyzer.py tests/unit/test_evaluate_analyzer.py && mypy app/scripts/evaluate_analyzer.py
git add backend/app/scripts/evaluate_analyzer.py backend/tests/unit/test_evaluate_analyzer.py backend/tests/fixtures/slopes/label_overrides.json docs/superpowers/specs/2026-09-13-gps-segmentation-design.md
git commit -m "feat(backend): corpus scorer for the session analyzer"
```

---

### Task 9: Tuning, recorded scores, and the regression gate

**Files:**
- Create: `backend/tests/fixtures/slopes/expected_scores.json`, `backend/tests/unit/test_analyzer_corpus.py`
- Modify: `backend/app/services/analysis/config.py` (defaults only), `backend/tests/TEST_PLAN.md`

**Interfaces:**
- Consumes: `score_corpus`, `EXPECTED_PATH`, `AnalyzerConfig`.

- [ ] **Step 1: Write the gate test**

```python
# backend/tests/unit/test_analyzer_corpus.py
"""Regression gate for the session analyzer against the Slopes corpus (spec section 9.3)."""

import json

import pytest

from app.scripts.evaluate_analyzer import EXPECTED_PATH
from app.scripts.evaluate_analyzer import CorpusScore
from app.scripts.evaluate_analyzer import score_corpus
from app.services.analysis import AnalyzerConfig

OLD_ANALYZER_MEAN = 0.784
TOLERANCE = 0.005


@pytest.fixture(scope="module")
def corpus() -> CorpusScore:
    return score_corpus(AnalyzerConfig(), use_catalog=True)


def test_no_archive_regresses_below_its_recorded_score(corpus: CorpusScore) -> None:
    expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))
    assert set(expected) == {a.name for a in corpus.archives}
    for archive in corpus.archives:
        recorded = expected[archive.name]
        assert archive.agreement >= recorded["agreement"] - TOLERANCE, archive.name
        assert (archive.runs, archive.lifts) == (recorded["runs"], recorded["lifts"]), archive.name


def test_corpus_meets_the_success_bar(corpus: CorpusScore) -> None:
    assert corpus.mean_agreement >= 0.88
    assert min(a.agreement for a in corpus.archives) >= 0.75
    assert corpus.lift_recall >= 0.94
    assert corpus.lift_precision >= 0.93
    assert corpus.run_recall >= 0.90
    assert corpus.exact_count_archives >= 8


def test_corpus_beats_the_old_analyzer(corpus: CorpusScore) -> None:
    assert corpus.mean_agreement > OLD_ANALYZER_MEAN
```

- [ ] **Step 2: Tune**

Run `python -m app.scripts.evaluate_analyzer` for the starting table. The starting point is 86.1% mean, 7 of 14 exact, run recall 87.0%; the bar needs 88%, 8 of 14, and 90%, while lift recall (94.9%) and precision (93.0%) already meet it and must not fall. The weakest archives at the start are `cypress_2025-02-12` (76.3%), `grouse_2026-02-11` (76.7%), `grouse_2025-03-02` (78.5%), and `grouse_2026-03-13` (78.9%); their main error is seconds Slopes labels `run` that we leave as `other` (late run starts and runs cut short). Then sweep one group at a time with `--config`, keeping a change only when the corpus mean rises without any archive losing more than one point, and re-running the full `tests/unit/analysis` suite after each kept change (its synthetic tests must stay green; they are the guard against overfitting). Sweep in this order, which is ordered by the error the spike saw most:

1. Run starts and ends: `descent_slow_mps` in {0.5, 0.6, 0.8}, `descent_vrate_mps` in {-0.15, -0.2, -0.3}, `tail_min_drop_m` in {2, 3, 5}, `tiny_descent_m` in {15, 25, 40}.
2. Lift ends: `lift_radius_m` in {35, 45, 60}, `lift_bearing_deg` in {25, 30, 40}, `lift_gap_s` in {90, 150, 240}, `lift_riding_fraction` in {0.25, 0.35, 0.5}.
3. Smoothing: `gps_alt_window_s` in {11, 15, 21}, `vrate_half_window_s` in {4, 6, 8}.
4. Transitions: `switch_descent_stop` and `switch_stop_descent` in {-3, -4, -6}; `switch_stop_lift` and `switch_lift_stop` in {-4, -5, -7}.
5. Fallback lifts: `lift_vrate_mps` in {0.1, 0.15, 0.25}, `fallback_lift_min_gain_m` in {15, 20, 30}.

For the archive with the lowest agreement after the sweeps, print its timeline (our actions next to the labels, as offsets in seconds) and check whether a rule of spec section 8 is misapplied; fix rule bugs in code with a new synthetic test in `tests/unit/analysis/`. Do not add archive-specific conditions, resort names, or coordinates to the analyzer.

Write every kept value into the defaults in `config.py`.

Label overrides: you may propose further entries for `label_overrides.json` only when the track itself proves the label wrong (for example a labelled lift with a median speed under 1.5 m/s and under 30 m of gain). List each proposal with its evidence in the report; do not add it to the file. The user reviews additions.

- [ ] **Step 3: Decide the outcome honestly**

- If every assertion in `test_corpus_meets_the_success_bar` would pass: continue to Step 4.
- If not, after all five sweeps and the timeline review: do not lower the bar in the test and do not skip it. Record the scores (Step 4), mark `test_corpus_meets_the_success_bar` with `@pytest.mark.xfail(strict=True, reason="bar not yet met: <metric>=<value>")`, and report DONE_WITH_CONCERNS with the full table, the metric or metrics missed, and what you believe blocks them. The other two tests must pass either way.

- [ ] **Step 4: Record the scores and run the gate**

```bash
python -m app.scripts.evaluate_analyzer --write-expected
python -m pytest tests/unit/test_analyzer_corpus.py -q
```
Expected: 3 passed (or 2 passed and 1 xfailed under the Step 3 exception).

- [ ] **Step 5: Update `TEST_PLAN.md`**

Add under the unit-test section:

```markdown
- `tests/unit/test_analyzer_corpus.py` scores the analyzer against the fourteen Slopes archives with the recorded OSM lift lines. It fails when any archive drops more than 0.5 points below `tests/fixtures/slopes/expected_scores.json`, when the corpus falls under the success bar of the GPS segmentation spec, or when it no longer beats the old analyzer's 78.4%. Re-record scores with `python -m app.scripts.evaluate_analyzer --write-expected`; a lower recorded score must be justified in the same commit.
```

- [ ] **Step 6: Full backend verification and commit**

```bash
export DATABASE_URL="$(grep '^DATABASE_URL=' ../.env | cut -d= -f2- | sed 's#/goofyrider$#/goofyrider_test#')"
python -m pytest -q
ruff check app/services/analysis app/scripts/evaluate_analyzer.py app/services/osm_lift_mapping.py tests/unit/analysis tests/unit/test_analyzer_corpus.py
mypy app/services/analysis app/scripts/evaluate_analyzer.py app/services/osm_lift_mapping.py
git add backend/app/services/analysis/config.py backend/tests/fixtures/slopes/expected_scores.json backend/tests/unit/test_analyzer_corpus.py backend/tests/TEST_PLAN.md
git commit -m "test(backend): tuned analyzer defaults and the corpus regression gate"
```
Expected: the whole suite passes (234 tests before this plan, plus the new ones). Never print the contents of `.env`.
