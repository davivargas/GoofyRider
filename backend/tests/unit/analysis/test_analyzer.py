from datetime import timedelta

import pytest

from app.services.analysis import AnalyzerInput
from app.services.analysis import OverrideSpan
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
        record_start=points[0].recorded_at,
        record_end=points[-1].recorded_at,
        resort_id=None,
        source="live_recording",
    )
    return AnalyzerInput(points=points, metadata=metadata, **kwargs)


def test_live_path_produces_run_lift_run_with_summary_and_breaks() -> None:
    points = (
        descent(0, 90)
        + standstill(90, 150, north=-712.0, alt=733.0)
        + climb(240, 200, north0=-712.0, alt0=733.0)
        + standstill(440, 20, north=88.0, alt=1033.0)
        + descent(460, 90, north0=88.0, alt0=1033.0)
    )
    result = SessionAnalyzer(analyzer_version="analyzer@test").analyze(_input(points))
    assert [a.action_type for a in result.actions] == ["run", "lift", "run"]
    assert result.summary.break_count == 1
    assert result.summary.break_duration_s == pytest.approx(150, abs=12)
    assert result.summary.descent_vertical_m == pytest.approx(534, abs=30)
    assert result.analyzer_version == "analyzer@test"


def test_catalog_lift_gets_its_name() -> None:
    lift = ResortLift(
        name="Test Chair",
        polyline=((49.4, -123.0), (49.4 + 800 * DEG_LAT_PER_M, -123.0)),
        lift_type="chair",
        osm_aerialway="chair_lift",
        external_track_id="osm:way:1",
    )
    result = SessionAnalyzer(analyzer_version="v").analyze(
        _input(climb(0, 190), resort_lifts=(lift,))
    )
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
    points = (
        descent(0, 60)
        + standstill(60, 300, north=-472.0, alt=823.0)
        + descent(360, 60, north0=-472.0, alt0=823.0)
    )
    preset = PresetAction(
        action_type="run",
        sequence_index=1,
        started_at=points[0].recorded_at,
        ended_at=points[-1].recorded_at,
        duration_s=419.0,
        distance_m=900.0,
        avg_speed_mps=2.1,
        max_speed_mps=9.0,
    )
    result = SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_actions=[preset]))
    assert len(result.actions) == 1
    assert result.actions[0].source == "slopes_import"
    assert result.actions[0].duration_s == 419.0
    assert result.summary.break_count == 1


def test_invalid_preset_type_is_rejected() -> None:
    points = descent(0, 5)
    bad = PresetAction(
        action_type="walk",
        sequence_index=1,
        started_at=points[0].recorded_at,
        ended_at=points[-1].recorded_at,
        duration_s=4.0,
        distance_m=1.0,
        avg_speed_mps=1.0,
        max_speed_mps=1.0,
    )
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_actions=[bad]))


def test_record_end_before_record_start_is_rejected() -> None:
    points = descent(0, 5)
    metadata = SessionMetadataInput(
        record_start=points[-1].recorded_at,
        record_end=points[-1].recorded_at - timedelta(seconds=1),
        resort_id=None,
        source="live_recording",
    )
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(
            AnalyzerInput(points=points, metadata=metadata)
        )


def test_override_with_end_before_start_is_rejected() -> None:
    points = descent(0, 90)
    override = OverrideSpan(
        started_at=points[10].recorded_at,
        ended_at=points[10].recorded_at - timedelta(seconds=1),
        motion_state="ignore",
        created_by="user",
    )
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_overrides=[override]))


def test_frame_spanning_more_than_a_day_is_surfaced_as_validation_error() -> None:
    bridge = [standstill(3600 * k, 1, north=-1.0 * k, alt=1000.0)[0] for k in range(1, 25)]
    points = [*descent(0, 60), *bridge, *descent(25 * 3600, 60, north0=-24.0)]
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(_input(points))


def test_override_with_unknown_motion_state_is_rejected() -> None:
    points = descent(0, 90)
    override = OverrideSpan(
        started_at=points[10].recorded_at,
        ended_at=points[20].recorded_at,
        motion_state="walk",
        created_by="user",
    )
    with pytest.raises(ValidationError):
        SessionAnalyzer(analyzer_version="v").analyze(_input(points, preset_overrides=[override]))
