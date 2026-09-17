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
GONDOLA = ResortLift(
    name="Test Gondola",
    polyline=CHAIR.polyline,
    lift_type="gondola",
    osm_aerialway="gondola",
    external_track_id="osm:way:2",
)


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
    down = [
        point(i, north_m=800.0 - 8.0 * i, altitude_m=1900.0 - 3.0 * i, speed_mps=8.0)
        for i in range(100)
    ]
    assert anchor(_frame(down), [CHAIR], CONFIG) == []


def test_riding_a_gondola_down_is_a_lift() -> None:
    down = [
        point(i, north_m=800.0 - 4.0 * i, altitude_m=1900.0 - 1.5 * i, speed_mps=4.0)
        for i in range(200)
    ]
    spans = anchor(_frame(down), [GONDOLA], CONFIG)
    assert len(spans) == 1


def test_crossing_the_line_is_not_a_lift() -> None:
    across = [
        point(i, north_m=400.0, east_m=-200.0 + 4.0 * i, altitude_m=1000.0 + 0.5 * i, speed_mps=4.0)
        for i in range(100)
    ]
    assert anchor(_frame(across), [CHAIR], CONFIG) == []


def test_parallel_track_eighty_metres_away_is_not_a_lift() -> None:
    beside = [
        point(i, north_m=4.0 * i, east_m=80.0, altitude_m=700.0 + 1.5 * i, speed_mps=4.0)
        for i in range(190)
    ]
    assert anchor(_frame(beside), [CHAIR], CONFIG) == []


def test_skiing_away_past_the_top_terminal_does_not_extend_the_lift() -> None:
    ride = climb(0, 200)  # reaches 796 m north
    away = [
        point(200 + i, north_m=800.0 + 5.0 * i, altitude_m=1000.0 - 1.0 * i, speed_mps=5.0)
        for i in range(60)
    ]
    spans = anchor(_frame(ride + away), [CHAIR], CONFIG)
    assert len(spans) == 1
    assert spans[0].end <= 206


def test_resort_area_pads_the_lift_bounding_box() -> None:
    area = resort_area([CHAIR], CONFIG)
    assert area is not None
    min_lat, max_lat, _, _ = area
    assert min_lat < 49.4 and max_lat > 49.4 + 800 * DEG_LAT_PER_M
    assert resort_area([], CONFIG) is None


def test_lift_with_a_zero_length_polyline_is_ignored() -> None:
    broken = ResortLift(
        name="Broken",
        polyline=((49.4, -123.0), (49.4, -123.0)),
        lift_type="chair",
        osm_aerialway="chair_lift",
    )
    assert anchor(_frame(climb(0, 190)), [broken], CONFIG) == []
