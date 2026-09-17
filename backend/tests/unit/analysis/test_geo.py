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
