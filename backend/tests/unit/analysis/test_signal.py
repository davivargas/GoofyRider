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
    assert frame.speed[15] == pytest.approx(5.0, abs=0.3)


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
