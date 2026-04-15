from datetime import UTC
from datetime import datetime
from pathlib import Path
import textwrap
from uuid import UUID

from app.services.slopes_import_service import ParsedSlopesPoint
from app.services.slopes_import_service import build_session_points
from app.services.slopes_import_service import parse_gps_points
from app.services.slopes_import_service import parse_override_segments
from app.services.slopes_import_service import parse_slopes_archive
from app.services.slopes_import_service import parse_slopes_payload


def test_parse_override_segments_maps_known_states() -> None:
    segments = parse_override_segments("10-20:ignore;21-30:lift;31-40:run")

    assert [segment.motion_state for segment in segments] == [
        "stopped_idle",
        "lift_uphill",
        "active_descent",
    ]


def test_parse_gps_points_filters_to_record_window_and_maps_motion_states() -> None:
    gps_csv = textwrap.dedent(
        """
        1735905600.000000,49.0,-123.0,1000.0,10.0,2.0,0.5,4.0
        1735905601.000000,49.1,-123.1,1001.0,-1.0,0.0,0.5,4.0
        1735905602.000000,49.2,-123.2,1002.0,200.0,5.0,0.5,4.0
        1735905604.000000,49.4,-123.4,1004.0,180.0,3.0,0.5,4.0
        """
    ).strip()
    record_start = datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC)
    record_end = datetime(2025, 1, 3, 12, 0, 2, tzinfo=UTC)
    overrides = parse_override_segments("1735905600-1735905600:ignore;1735905601-1735905601:lift")

    points = parse_gps_points(
        gps_csv_text=gps_csv,
        record_start=record_start,
        record_end=record_end,
        motion_segments=overrides,
    )

    assert [point.t_offset_ms for point in points] == [0, 1000, 2000]
    assert points[0].motion_state == "stopped_idle"
    assert points[1].motion_state == "lift_uphill"
    assert points[2].motion_state == "stopped_idle"
    assert points[1].heading_deg is None
    assert points[0].distance_delta_m == 0
    assert points[1].distance_delta_m is not None


def test_build_session_points_sets_gps_provider_and_dual_write_analytics() -> None:
    parsed_points = [
        ParsedSlopesPoint(
            t_offset_ms=0,
            recorded_at=datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC),
            latitude=49.0,
            longitude=-123.0,
            altitude_m=1000.0,
            speed_mps=4.0,
            heading_deg=200.0,
            distance_delta_m=0.0,
            motion_state="active_descent",
        )
    ]

    models = build_session_points(
        session_id=UUID("00000000-0000-0000-0000-000000000001"),
        parsed_points=parsed_points,
    )

    assert len(models) == 1
    assert models[0].provider == "gps"
    assert models[0].quality_class == "accept"
    assert models[0].accepted_for_analytics is True
    assert models[0].motion_state == "active_descent"
    assert models[0].distance_delta_m == 0.0
    assert models[0].analytics is not None
    assert models[0].analytics.motion_state == "active_descent"
    assert models[0].analytics.quality_class == "accept"


def test_parse_slopes_payload_uses_record_window_and_action_verticals() -> None:
    metadata_xml = textwrap.dedent(
        """
        <Activity
            locationName="Cypress Mountain"
            recordStart="2025-01-03 04:00:00 -0800"
            recordEnd="2025-01-03 04:10:00 -0800"
            distance="600.0"
            topSpeed="12.5"
            overrides="1735905600-1735905601:ignore;1735905602-1735905603:run">
            <actions>
                <Action type="Lift" vertical="120.2" />
                <Action type="Run" vertical="220.8" />
            </actions>
        </Activity>
        """
    ).strip()
    gps_csv = textwrap.dedent(
        """
        1735905600.000000,49.0,-123.0,1000.0,10.0,2.0,0.5,4.0
        1735905602.000000,49.1,-123.1,1005.0,200.0,6.0,0.5,4.0
        1735906201.000000,49.2,-123.2,1008.0,180.0,1.0,0.5,4.0
        """
    ).strip()

    parsed = parse_slopes_payload(
        source_path=Path("sample.slopes"),
        metadata_xml=metadata_xml,
        gps_csv_text=gps_csv,
    )

    assert parsed.resort_name == "Cypress Mountain"
    assert parsed.started_at == datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC)
    assert parsed.ended_at == datetime(2025, 1, 3, 12, 10, 0, tzinfo=UTC)
    assert parsed.duration_s == 600
    assert parsed.avg_speed_mps == 1.0
    assert parsed.elevation_gain_m == 120
    assert parsed.elevation_loss_m == 221
    assert [point.motion_state for point in parsed.points] == [
        "stopped_idle",
        "active_descent",
    ]


def test_parse_slopes_archive_reads_zip_entries() -> None:
    archive_path = Path(
        r"c:\Users\daviv\Downloads\attachments\January 18 2026 - Grouse Mountain.slopes"
    )

    parsed = parse_slopes_archive(archive_path)

    assert parsed.resort_name == "Grouse Mountain"
    assert parsed.duration_s > 0
    assert len(parsed.points) > 0


def test_parse_slopes_archive_falls_back_to_actions_when_overrides_are_sparse() -> None:
    archive_path = Path(
        r"c:\Users\daviv\Downloads\attachments\January 3 2025 - Cypress Mountain.slopes"
    )

    parsed = parse_slopes_archive(archive_path)

    assert parsed.resort_name == "Cypress Mountain"
    assert len(parsed.points) > 0
    assert any(point.motion_state == "lift_uphill" for point in parsed.points)
    assert any(point.motion_state == "active_descent" for point in parsed.points)
    assert all(point.motion_state is not None for point in parsed.points)
