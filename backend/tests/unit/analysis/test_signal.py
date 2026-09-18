import pytest

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.signal import condition
from app.services.analysis.signal import smooth_speeds_centered_mean
from app.services.exceptions import ValidationError
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
    points.insert(
        10, point(5.0, north_m=-40.0, altitude_m=985.0, speed_mps=8.0)
    )  # time goes backwards
    points.insert(15, point(14.5, north_m=-116.0, altitude_m=956.0, speed_mps=8.0, accuracy_m=80.0))
    points.insert(20, point(19.5, north_m=-5000.0, altitude_m=940.0, speed_mps=8.0))  # teleport
    frame = condition(points, CONFIG)
    assert frame is not None
    assert len(frame.points) == 30
    assert min(frame.lat) > 49.4 - 300 / 110_540.0


def test_stationary_gap_is_bridged_as_a_stop() -> None:
    points = [
        point(0, north_m=0.0),
        point(1, north_m=0.0),
        point(400, north_m=2.0),
        point(401, north_m=2.0),
    ]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert len(frame) == 402
    assert max(frame.speed[5:395]) == 0.0
    assert not any(frame.gap)


def test_short_moving_gap_is_interpolated() -> None:
    points = [
        point(0, north_m=0.0, speed_mps=5.0),
        point(1, north_m=-5.0, speed_mps=5.0),
        point(21, north_m=-105.0, speed_mps=5.0),
        point(22, north_m=-110.0, speed_mps=5.0),
    ]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert frame.speed[11] == pytest.approx(5.0, abs=0.3)
    assert not any(frame.gap)


def test_long_moving_gap_is_marked_unknown() -> None:
    points = [
        point(0, north_m=0.0, speed_mps=5.0),
        point(1, north_m=-5.0, speed_mps=5.0),
        point(121, north_m=-605.0, speed_mps=5.0),
        point(122, north_m=-610.0, speed_mps=5.0),
    ]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert all(frame.gap[2:120])
    assert not frame.gap[0]


def test_untrusted_platform_speed_is_replaced_by_position_speed() -> None:
    points = [point(i, north_m=-5.0 * i, speed_mps=40.0, speed_accuracy_mps=9.0) for i in range(30)]
    frame = condition(points, CONFIG)
    assert frame is not None
    # 30 m of displacement over the 6 s centred window, less the 5 m accuracy slack.
    assert frame.speed[15] == pytest.approx(4.2, abs=0.3)


def _jittery_stop(start_s: int, seconds: int, *, north: float, alt: float) -> list:
    """A stationary rider whose fixes jitter +/- 8 m and whose platform speed is junk."""
    return [
        point(
            start_s + i,
            north_m=north + (8.0 if i % 2 else -8.0),
            altitude_m=alt,
            speed_mps=40.0,
            accuracy_m=25.0,
            speed_accuracy_mps=5.0,
        )
        for i in range(seconds)
    ]


def test_jittery_stationary_fixes_do_not_read_as_movement() -> None:
    frame = condition(_jittery_stop(0, 300, north=0.0, alt=1000.0), CONFIG)
    assert frame is not None
    assert sum(frame.speed) / len(frame.speed) < 0.3


def test_untrusted_moving_rider_keeps_a_realistic_speed() -> None:
    points = [
        point(
            i, north_m=-8.0 * i, altitude_m=1000.0 - 3.0 * i, speed_mps=40.0, speed_accuracy_mps=5.0
        )
        for i in range(60)
    ]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert 6.0 < frame.speed[30] < 8.5


def test_barometer_removes_gps_altitude_noise() -> None:
    noisy = [1000.0 + (12.0 if i % 2 else -12.0) for i in range(120)]
    points = [
        point(i, north_m=0.0, altitude_m=noisy[i], pressure_hpa=898.7, vertical_accuracy_m=10.0)
        for i in range(120)
    ]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert frame.used_barometer
    assert max(frame.alt) - min(frame.alt) < 3.0
    assert abs(sum(frame.alt) / len(frame.alt) - 1000.0) < 8.0


def _noisy_baro_points(seconds: int, *, pressure_at) -> list:
    noisy = [1000.0 + (12.0 if i % 2 else -12.0) for i in range(seconds)]
    return [
        point(
            i,
            north_m=0.0,
            altitude_m=noisy[i],
            pressure_hpa=pressure_at(i),
            vertical_accuracy_m=10.0,
        )
        for i in range(seconds)
    ]


def test_barometer_survives_a_few_missing_pressure_samples() -> None:
    frame = condition(
        _noisy_baro_points(400, pressure_at=lambda i: None if i % 40 == 7 else 898.7), CONFIG
    )
    assert frame is not None
    assert frame.used_barometer
    assert max(frame.alt) - min(frame.alt) < 3.0
    assert abs(sum(frame.alt) / len(frame.alt) - 1000.0) < 8.0


def test_partial_pressure_coverage_falls_back_to_gps_altitude() -> None:
    frame = condition(
        _noisy_baro_points(400, pressure_at=lambda i: 898.7 if i < 240 else None), CONFIG
    )
    assert frame is not None
    assert not frame.used_barometer


def test_speed_smoothing_canonical_reference() -> None:
    raw = [
        1.0,
        2.0,
        3.0,
        4.0,
        5.0,
        6.0,
        7.0,
        8.0,
        9.0,
        10.0,
        9.0,
        8.0,
        7.0,
        6.0,
        5.0,
        4.0,
        3.0,
        2.0,
        1.0,
        0.0,
    ]
    expected = [
        1.6,
        2.2,
        3.0,
        4.0,
        5.0,
        6.0,
        7.0,
        8.0,
        8.6,
        8.8,
        8.6,
        8.0,
        7.0,
        6.0,
        5.0,
        4.0,
        3.0,
        2.0,
        1.2,
        0.6,
    ]
    assert smooth_speeds_centered_mean(raw) == pytest.approx(expected, abs=1e-9)


def test_sub_second_recording_yields_no_frame() -> None:
    assert condition([point(0.0), point(0.4, north_m=1.0)], CONFIG) is None


def test_point_after_a_huge_gap_is_dropped() -> None:
    points = [*descent(0, 60), point(3 * 3600, north_m=-480.0, altitude_m=820.0)]
    frame = condition(points, CONFIG)
    assert frame is not None
    assert len(frame.points) == 60
    assert frame.points[-1].recorded_at == points[59].recorded_at
    assert len(frame) == 60


def test_frame_spanning_more_than_a_day_is_rejected() -> None:
    bridge = [point(3600 * k, north_m=-1.0 * k, altitude_m=1000.0) for k in range(1, 25)]
    points = [*descent(0, 60), *bridge, *descent(25 * 3600, 60, north0=-24.0)]
    with pytest.raises(ValidationError):
        condition(points, CONFIG)
