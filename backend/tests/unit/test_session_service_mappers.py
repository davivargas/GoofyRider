from datetime import UTC
from datetime import datetime

from app.services.analysis import ActionRecord
from app.services.analysis import SessionSummaryFields
from app.services.session_service import _summary_to_fields
from app.services.session_service import _to_action_model


def test_summary_fields_include_break_stats() -> None:
    summary = SessionSummaryFields(
        total_duration_s=100.0,
        descent_duration_s=50.0,
        lift_duration_s=20.0,
        descent_distance_m=500.0,
        lift_distance_m=300.0,
        descent_vertical_m=80.0,
        lift_vertical_m=90.0,
        max_speed_mps=9.0,
        avg_descent_speed_mps=7.0,
        peak_altitude_m=1200.0,
        center_lat=49.4,
        center_long=-123.0,
        altitude_offset_m=0.0,
        break_count=2,
        break_duration_s=310.0,
    )
    fields = _summary_to_fields(summary)
    assert fields["break_count"] == 2
    assert fields["break_duration_s"] == 310.0


def test_action_model_carries_lift_name() -> None:
    now = datetime(2026, 2, 1, 10, 0, tzinfo=UTC)
    record = ActionRecord(
        action_type="lift",
        sequence_index=1,
        started_at=now,
        ended_at=now,
        duration_s=0.0,
        distance_m=0.0,
        avg_speed_mps=0.0,
        max_speed_mps=0.0,
        min_speed_mps=None,
        vertical_m=None,
        min_altitude_m=None,
        max_altitude_m=None,
        min_lat=None,
        max_lat=None,
        min_long=None,
        max_long=None,
        top_speed_lat=None,
        top_speed_long=None,
        top_speed_alt_m=None,
        time_of_day=None,
        external_track_id="osm:way:1",
        source="live_analyzer",
        lift_name="Peak Chair",
    )
    model = _to_action_model(record)
    assert model.lift_name == "Peak Chair"
    assert model.external_track_id == "osm:way:1"
