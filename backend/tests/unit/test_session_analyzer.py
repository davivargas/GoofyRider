from __future__ import annotations

from datetime import UTC
from datetime import datetime
from datetime import timedelta
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

import pytest

from app.services.session_analyzer import AnalyzerInput
from app.services.session_analyzer import PresetAction
from app.services.session_analyzer import RawPoint
from app.services.session_analyzer import SessionAnalyzer
from app.services.session_analyzer import SessionMetadataInput
from app.services.session_analyzer import smooth_speeds_centered_mean

_CYPRESS_FIXTURE = (
    Path(__file__).resolve().parent.parent / "fixtures" / "slopes" / "cypress_2026-03-21.slopes"
)
_SLOPES_DT_FORMAT = "%Y-%m-%d %H:%M:%S %z"

DURATION_ABS = 0.5
DISTANCE_ABS = 1.0
SPEED_ABS = 0.01
ALTITUDE_ABS = 0.5

_TEST_ANALYZER_VERSION = "analyzer@test"


def _parse_cypress_presets() -> tuple[datetime, datetime, list[PresetAction]]:
    with zipfile.ZipFile(_CYPRESS_FIXTURE) as archive:
        metadata_root = ET.fromstring(archive.read("Metadata.xml"))

    record_start = datetime.strptime(metadata_root.attrib["recordStart"], _SLOPES_DT_FORMAT)
    record_end = datetime.strptime(metadata_root.attrib["recordEnd"], _SLOPES_DT_FORMAT)

    actions_root = metadata_root.find("actions")
    assert actions_root is not None

    run_seq = 0
    lift_seq = 0
    presets: list[PresetAction] = []
    for action in actions_root.findall("Action"):
        raw_type = action.attrib["type"]
        if raw_type == "Run":
            run_seq += 1
            sequence_index = run_seq
            action_type = "run"
        elif raw_type == "Lift":
            lift_seq += 1
            sequence_index = lift_seq
            action_type = "lift"
        else:
            raise AssertionError(f"Unexpected action type: {raw_type!r}")
        started_at = datetime.strptime(action.attrib["start"], _SLOPES_DT_FORMAT)
        ended_at = datetime.strptime(action.attrib["end"], _SLOPES_DT_FORMAT)
        presets.append(
            PresetAction(
                action_type=action_type,
                sequence_index=sequence_index,
                started_at=started_at,
                ended_at=ended_at,
                duration_s=float(action.attrib["duration"]),
                distance_m=float(action.attrib["distance"]),
                avg_speed_mps=float(action.attrib["avgSpeed"]),
                max_speed_mps=float(action.attrib["topSpeed"]),
                min_speed_mps=float(action.attrib.get("minSpeed", 0.0)),
                vertical_m=float(action.attrib["vertical"]),
                min_altitude_m=float(action.attrib["minAlt"]),
                max_altitude_m=float(action.attrib["maxAlt"]),
                min_lat=float(action.attrib["minLat"]),
                max_lat=float(action.attrib["maxLat"]),
                min_long=float(action.attrib["minLong"]),
                max_long=float(action.attrib["maxLong"]),
                top_speed_lat=float(action.attrib["topSpeedLat"]),
                top_speed_long=float(action.attrib["topSpeedLong"]),
                top_speed_alt_m=float(action.attrib["topSpeedAlt"]),
                time_of_day=int(action.attrib["timeOfDay"]),
                external_track_id=action.attrib.get("trackIDs") or None,
            )
        )
    return record_start, record_end, presets


def _base_metadata(
    *,
    record_start: datetime,
    record_end: datetime,
    source: str,
) -> SessionMetadataInput:
    return SessionMetadataInput(
        record_start=record_start,
        record_end=record_end,
        resort_id=None,
        source=source,
    )


def _make_point(
    *,
    index: int,
    latitude: float,
    longitude: float,
    altitude_m: float | None,
    speed_mps: float,
    base_time: datetime,
    interval_s: float = 1.0,
) -> RawPoint:
    return RawPoint(
        t_offset_ms=int(index * interval_s * 1000),
        recorded_at=base_time + timedelta(seconds=index * interval_s),
        latitude=latitude,
        longitude=longitude,
        altitude_m=altitude_m,
        speed_mps=speed_mps,
        accuracy_m=5.0,
    )


# ---------------------------------------------------------------------------
# Canonical speed smoothing reference
# ---------------------------------------------------------------------------


def test_speed_smoothing_canonical_reference() -> None:
    raw_speeds = [
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
    smoothed = smooth_speeds_centered_mean(raw_speeds)
    assert smoothed == pytest.approx(expected, abs=1e-9)


# ---------------------------------------------------------------------------
# Import-path — Cypress Mar 21 2026
# ---------------------------------------------------------------------------


def test_cypress_fixture_import_path_totals_match_plan() -> None:
    record_start, record_end, presets = _parse_cypress_presets()
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)

    result = analyzer.analyze(
        AnalyzerInput(
            points=[],
            metadata=_base_metadata(
                record_start=record_start,
                record_end=record_end,
                source="slopes_import",
            ),
            preset_actions=presets,
            preset_overrides=[],
        )
    )

    summary = result.summary
    assert summary.total_duration_s == pytest.approx(15105, abs=DURATION_ABS)
    assert summary.descent_duration_s == pytest.approx(6956, abs=DURATION_ABS)
    assert summary.lift_duration_s == pytest.approx(2796, abs=DURATION_ABS)
    assert summary.max_speed_mps == pytest.approx(12.45, abs=SPEED_ABS)
    assert summary.avg_descent_speed_mps == pytest.approx(6.42, abs=SPEED_ABS)

    derived_idle = summary.total_duration_s - summary.descent_duration_s - summary.lift_duration_s
    assert derived_idle == pytest.approx(5353, abs=DISTANCE_ABS)

    action_types = {action.action_type for action in result.actions}
    assert action_types <= {"run", "lift"}

    assert result.analyzer_version == _TEST_ANALYZER_VERSION


# ---------------------------------------------------------------------------
# Live path — synthetic descent (via the shim, end to end)
# ---------------------------------------------------------------------------


def _build_linear_descent(
    *,
    base_time: datetime,
    sample_count: int,
    speed_mps: float,
    altitude_drop_per_sample_m: float,
    interval_s: float = 1.0,
    start_altitude_m: float = 1000.0,
    start_latitude: float = 49.4,
    start_longitude: float = -123.0,
    deg_lat_per_sample: float = 0.00009,
) -> list[RawPoint]:
    points: list[RawPoint] = []
    for i in range(sample_count):
        points.append(
            _make_point(
                index=i,
                latitude=start_latitude + i * deg_lat_per_sample,
                longitude=start_longitude,
                altitude_m=start_altitude_m - i * altitude_drop_per_sample_m,
                speed_mps=speed_mps,
                base_time=base_time,
                interval_s=interval_s,
            )
        )
    return points


def test_shim_live_path_synthetic_descent() -> None:
    base_time = datetime(2026, 2, 1, 10, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time, sample_count=90, speed_mps=10.0, altitude_drop_per_sample_m=5.0
    )
    result = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION).analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
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
        base_time=base_time,
        sample_count=90,
        speed_mps=10.0,
        altitude_drop_per_sample_m=5.0,
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
                record_start=points[0].recorded_at,
                record_end=flyaway.recorded_at,
                source="live_recording",
            ),
        )
    )
    assert result.summary.peak_altitude_m is not None
    assert result.summary.peak_altitude_m < 1300.0


def test_shim_exports_the_config_type() -> None:
    from app.services.session_analyzer import AnalyzerConfig

    assert AnalyzerConfig().long_stop_s == 120
