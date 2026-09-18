from datetime import UTC
from datetime import datetime
import json
from unittest.mock import MagicMock
import uuid

from app.models.resort_lift import ResortLift as ResortLiftModel
from app.models.ride_session import RideSession
from app.services.analysis import AnalysisResult
from app.services.analysis import SessionSummaryFields
from app.services.session_service import SessionService
from app.services.session_service import _to_analyzer_lift


def _summary() -> SessionSummaryFields:
    return SessionSummaryFields(
        total_duration_s=0.0,
        descent_duration_s=0.0,
        lift_duration_s=0.0,
        descent_distance_m=0.0,
        lift_distance_m=0.0,
        descent_vertical_m=0.0,
        lift_vertical_m=0.0,
        max_speed_mps=None,
        avg_descent_speed_mps=None,
        peak_altitude_m=None,
        center_lat=None,
        center_long=None,
        altitude_offset_m=0.0,
    )


def _lift_model(polyline: str | None) -> ResortLiftModel:
    return ResortLiftModel(
        resort_id=uuid.uuid4(),
        name="Peak Chair",
        lift_type="chair",
        osm_aerialway="chair_lift",
        polyline=polyline,
        external_track_id="osm:way:9",
    )


def test_analyzer_lift_is_built_from_json_polyline() -> None:
    lift = _to_analyzer_lift(_lift_model(json.dumps([[49.4, -123.0], [49.41, -123.0]])))
    assert lift is not None
    assert lift.name == "Peak Chair"
    assert lift.osm_aerialway == "chair_lift"
    assert lift.external_track_id == "osm:way:9"
    assert lift.polyline == ((49.4, -123.0), (49.41, -123.0))


def test_unusable_polylines_are_skipped() -> None:
    assert _to_analyzer_lift(_lift_model(None)) is None
    assert _to_analyzer_lift(_lift_model("not json")) is None
    assert _to_analyzer_lift(_lift_model(json.dumps([[49.4, -123.0]]))) is None


def test_non_numeric_pair_members_are_skipped_without_raising() -> None:
    polyline = json.dumps(
        [
            [49.4, -123.0],
            ["bad", -123.0],
            [49.41, -123.0],
        ]
    )

    lift = _to_analyzer_lift(_lift_model(polyline))

    assert lift is not None
    assert lift.polyline == ((49.4, -123.0), (49.41, -123.0))


def test_run_analysis_passes_catalog_lifts_to_the_analyzer() -> None:
    analyzer = MagicMock()
    analyzer.analyze.return_value = AnalysisResult(
        summary=_summary(), actions=[], overrides=[], analyzer_version="v"
    )
    lift_repo = MagicMock()
    lift_repo.list_by_resort.return_value = [
        _lift_model(json.dumps([[49.4, -123.0], [49.41, -123.0]]))
    ]
    points_repo = MagicMock()
    points_repo.list_by_session.return_value = []
    sessions_repo = MagicMock()
    service = SessionService(
        ride_session_repository=sessions_repo,
        resort_repository=MagicMock(),
        session_point_repository=points_repo,
        session_override_repository=MagicMock(),
        session_analyzer=analyzer,
        resort_lift_repository=lift_repo,
    )
    resort_id = uuid.uuid4()
    ride_session = RideSession(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        resort_id=resort_id,
        started_at=datetime(2026, 2, 1, 10, 0, tzinfo=UTC),
        ended_at=datetime(2026, 2, 1, 11, 0, tzinfo=UTC),
        source="live_recording",
        sport="snowboard",
    )

    service._run_analysis(ride_session, include_overrides=False)

    lift_repo.list_by_resort.assert_called_once_with(resort_id)
    analyzer_input = analyzer.analyze.call_args.args[0]
    assert [lift.name for lift in analyzer_input.resort_lifts] == ["Peak Chair"]


def test_run_analysis_without_resort_passes_no_lifts() -> None:
    analyzer = MagicMock()
    analyzer.analyze.return_value = AnalysisResult(
        summary=_summary(), actions=[], overrides=[], analyzer_version="v"
    )
    lift_repo = MagicMock()
    points_repo = MagicMock()
    points_repo.list_by_session.return_value = []
    service = SessionService(
        ride_session_repository=MagicMock(),
        resort_repository=MagicMock(),
        session_point_repository=points_repo,
        session_override_repository=MagicMock(),
        session_analyzer=analyzer,
        resort_lift_repository=lift_repo,
    )
    ride_session = RideSession(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        resort_id=None,
        started_at=datetime(2026, 2, 1, 10, 0, tzinfo=UTC),
        ended_at=None,
        source="live_recording",
        sport="snowboard",
    )
    service._run_analysis(ride_session, include_overrides=False)
    lift_repo.list_by_resort.assert_not_called()
    assert analyzer.analyze.call_args.args[0].resort_lifts == ()
