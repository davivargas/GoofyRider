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
    points = (
        descent(0, 60)
        + standstill(60, 40, north=-472.0, alt=823.0)
        + descent(100, 60, north0=-472.0, alt0=823.0)
    )
    actions, breaks = _analyze(points)
    assert len(_runs(actions)) == 1
    assert _runs(actions)[0].duration_s == pytest.approx(159, abs=3)
    assert breaks.count == 0


def test_long_stop_between_descents_is_masked_and_counted_as_a_break() -> None:
    points = (
        descent(0, 60)
        + standstill(60, 300, north=-472.0, alt=823.0)
        + descent(360, 60, north0=-472.0, alt0=823.0)
    )
    actions, breaks = _analyze(points)
    runs = _runs(actions)
    assert len(runs) == 1
    assert (runs[0].ended_at - runs[0].started_at).total_seconds() == pytest.approx(419, abs=3)
    assert runs[0].duration_s == pytest.approx(120, abs=12)
    assert runs[0].avg_speed_mps > 6.0
    assert breaks.count == 1
    assert breaks.duration_s == pytest.approx(300, abs=12)


def test_stop_followed_by_a_lift_ends_the_run_at_the_stop() -> None:
    points = (
        descent(0, 60)
        + standstill(60, 200, north=-472.0, alt=823.0)
        + climb(260, 200, north0=-472.0, alt0=823.0)
    )
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
    shuffle = [
        point(130 + i, north_m=-792.0 - 3.0 * i, altitude_m=703.0, speed_mps=3.0) for i in range(60)
    ]
    points = descent(0, 100) + pause + shuffle
    runs = _runs(_analyze(points)[0])
    assert len(runs) == 1
    assert (runs[0].ended_at - BASE_TIME).total_seconds() == pytest.approx(100, abs=8)


def test_slow_traverse_before_the_first_descent_starts_the_run() -> None:
    traverse = [
        point(i, north_m=-3.0 * i, altitude_m=1000.0 - 0.1 * i, speed_mps=3.0) for i in range(60)
    ]
    points = traverse + descent(60, 100, north0=-180.0, alt0=994.0)
    runs = _runs(_analyze(points)[0])
    assert len(runs) == 1
    assert (runs[0].started_at - BASE_TIME).total_seconds() <= 12


def test_vehicle_speed_is_never_a_run() -> None:
    drive = [
        point(i, north_m=-32.0 * i, altitude_m=1000.0 - 2.0 * i, speed_mps=32.0) for i in range(120)
    ]
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
    points = (
        climb(0, 120)
        + standstill(120, 90, north=480.0, alt=880.0)
        + climb(210, 120, north0=480.0, alt0=880.0)
    )
    assert len(_lifts(_analyze(points)[0])) == 1


def test_ignore_override_masks_stats_without_splitting() -> None:
    points = descent(0, 90)
    override = OverrideSpan(
        started_at=points[30].recorded_at,
        ended_at=points[49].recorded_at,
        motion_state="ignore",
        created_by="user",
    )
    runs = _runs(_analyze(points, overrides=[override])[0])
    assert len(runs) == 1
    assert runs[0].duration_s == pytest.approx(69, abs=3)


def test_lift_override_inside_a_descent_splits_it() -> None:
    points = descent(0, 150)
    override = OverrideSpan(
        started_at=points[60].recorded_at,
        ended_at=points[89].recorded_at,
        motion_state="lift",
        created_by="user",
    )
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
    points = (
        descent(0, 60)
        + standstill(60, 30, north=-472.0, alt=823.0)
        + climb(90, 200, north0=-472.0, alt0=823.0)
        + standstill(290, 30, north=328.0, alt=1123.0)
        + descent(320, 60, north0=328.0, alt0=1123.0)
    )
    actions, _ = _analyze(points)
    assert [a.sequence_index for a in _runs(actions)] == [1, 2]
    assert [a.sequence_index for a in _lifts(actions)] == [1]
    assert [a.action_type for a in actions] == ["run", "lift", "run"]
