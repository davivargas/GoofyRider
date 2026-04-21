from __future__ import annotations

from datetime import UTC
from datetime import datetime
from datetime import timedelta
from pathlib import Path
import uuid
import xml.etree.ElementTree as ET
import zipfile

import pytest

from app.services.exceptions import ValidationError
from app.services.session_analyzer import AnalyzerInput
from app.services.session_analyzer import OverrideSpan
from app.services.session_analyzer import PresetAction
from app.services.session_analyzer import RawPoint
from app.services.session_analyzer import ResortLift
from app.services.session_analyzer import SessionAnalyzer
from app.services.session_analyzer import SessionMetadataInput
from app.services.session_analyzer import smooth_speeds_centered_mean


_CYPRESS_FIXTURE = (
    Path(__file__).resolve().parent.parent
    / "fixtures"
    / "slopes"
    / "cypress_2026-03-21.slopes"
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

    record_start = datetime.strptime(
        metadata_root.attrib["recordStart"], _SLOPES_DT_FORMAT
    )
    record_end = datetime.strptime(
        metadata_root.attrib["recordEnd"], _SLOPES_DT_FORMAT
    )

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
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0,
        9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0,
    ]
    expected = [
        1.6, 2.2, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 8.6, 8.8,
        8.6, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.2, 0.6,
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

    derived_idle = (
        summary.total_duration_s
        - summary.descent_duration_s
        - summary.lift_duration_s
    )
    assert derived_idle == pytest.approx(5353, abs=DISTANCE_ABS)

    action_types = {action.action_type for action in result.actions}
    assert action_types <= {"run", "lift"}

    assert result.analyzer_version == _TEST_ANALYZER_VERSION


# ---------------------------------------------------------------------------
# Live path — synthetic descent
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


def test_live_path_synthetic_descent_durations_and_distance() -> None:
    base_time = datetime(2026, 2, 1, 10, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time,
        sample_count=20,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)

    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )

    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    run = runs[0]
    # 20 samples at ~10 m/s for 1 s each; the first sample has no prior
    # altitude so classifies as ignore. Expect ~18 s of descent duration for
    # samples 1..19. Distance is haversine across 18 strides of ~9.99 m.
    assert result.summary.descent_duration_s == pytest.approx(18, abs=DURATION_ABS)
    expected_distance_m = 18 * 9.99
    assert run.distance_m == pytest.approx(expected_distance_m, abs=DISTANCE_ABS + 5.0)


# ---------------------------------------------------------------------------
# GPS speed-spike filter — rejects one-sample pathologies from per-action
# max_speed_mps / top_speed_* while keeping real sharp peaks
# ---------------------------------------------------------------------------


def test_gps_spike_rejected_from_max_and_top_speed() -> None:
    base_time = datetime(2026, 2, 1, 10, 30, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time,
        sample_count=20,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    spike_original = points[10]
    points[10] = RawPoint(
        t_offset_ms=spike_original.t_offset_ms,
        recorded_at=spike_original.recorded_at,
        latitude=spike_original.latitude,
        longitude=spike_original.longitude,
        altitude_m=spike_original.altitude_m,
        speed_mps=50.0,
        accuracy_m=spike_original.accuracy_m,
    )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)

    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )

    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    run = runs[0]
    assert run.max_speed_mps == pytest.approx(10.0, abs=SPEED_ABS)
    assert run.top_speed_lat != pytest.approx(spike_original.latitude, abs=1e-9)


def test_real_sharp_peak_survives_spike_filter() -> None:
    base_time = datetime(2026, 2, 1, 10, 45, 0, tzinfo=UTC)
    speeds = [
        10.0, 10.0, 10.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 14.0,
        13.0, 12.0, 11.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0,
    ]
    points: list[RawPoint] = []
    for i, speed in enumerate(speeds):
        points.append(
            _make_point(
                index=i,
                latitude=49.4 + i * 0.00009,
                longitude=-123.0,
                altitude_m=1000.0 - i * 10.0,
                speed_mps=speed,
                base_time=base_time,
            )
        )
    peak_latitude = points[8].latitude
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)

    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )

    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    run = runs[0]
    assert run.max_speed_mps == pytest.approx(15.0, abs=SPEED_ABS)
    assert run.top_speed_lat == pytest.approx(peak_latitude, abs=1e-9)


# ---------------------------------------------------------------------------
# Speed-fallback (empty catalog) lift classification
# ---------------------------------------------------------------------------


def test_speed_fallback_slow_uphill_classifies_as_lift_without_catalog() -> None:
    base_time = datetime(2026, 2, 1, 11, 0, 0, tzinfo=UTC)
    points: list[RawPoint] = []
    for i in range(20):
        points.append(
            _make_point(
                index=i,
                latitude=49.40 + i * 0.00005,
                longitude=-123.00,
                altitude_m=900.0 + i * 2.0,
                speed_mps=3.0,
                base_time=base_time,
            )
        )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
            resort_lifts=(),
        )
    )

    lifts = [a for a in result.actions if a.action_type == "lift"]
    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(lifts) == 1
    assert runs == []
    # First sample has no prior altitude so classifies as ignore; expect
    # 19-sample lift action (samples 1..19) with a duration of ~18 s.
    assert result.summary.lift_duration_s == pytest.approx(18, abs=DURATION_ABS)


# ---------------------------------------------------------------------------
# Gap tolerance — contiguity is sample-ordered, not wall-clock
# ---------------------------------------------------------------------------


def test_gap_tolerance_200_second_internal_gap_yields_single_run() -> None:
    base_time = datetime(2026, 2, 1, 12, 0, 0, tzinfo=UTC)
    first_leg = _build_linear_descent(
        base_time=base_time,
        sample_count=10,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    # Jump forward 200 s in wall-clock with no intervening samples.
    gap_start_time = first_leg[-1].recorded_at + timedelta(seconds=200)
    second_leg_start_altitude = first_leg[-1].altitude_m - 5.0
    second_leg = []
    for i in range(10):
        second_leg.append(
            RawPoint(
                t_offset_ms=first_leg[-1].t_offset_ms + int((200 + i) * 1000),
                recorded_at=gap_start_time + timedelta(seconds=i),
                latitude=first_leg[-1].latitude + (i + 1) * 0.00009,
                longitude=first_leg[-1].longitude,
                altitude_m=second_leg_start_altitude - i * 10.0,
                speed_mps=10.0,
                accuracy_m=5.0,
            )
        )
    points = first_leg + second_leg
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)

    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )
    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1


# ---------------------------------------------------------------------------
# Override semantics
# ---------------------------------------------------------------------------


def test_ignore_override_masks_stats_but_does_not_split_action() -> None:
    base_time = datetime(2026, 2, 1, 13, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time,
        sample_count=30,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    # Override: mask out samples 10..19 inclusive (10 s window).
    override = OverrideSpan(
        started_at=points[10].recorded_at,
        ended_at=points[19].recorded_at,
        motion_state="ignore",
        created_by="importer",
    )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[override],
        )
    )

    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    run = runs[0]
    # Sample 0 is ignore (no prior altitude); the Run action spans
    # samples 1..29 giving a wall-clock duration of 28 s.
    assert run.duration_s == pytest.approx(28, abs=DURATION_ABS)
    # Persisted overrides are returned verbatim for storage.
    assert len(result.overrides) == 1
    assert result.overrides[0].motion_state == "ignore"


def test_lift_override_crossing_run_boundary_splits_action() -> None:
    base_time = datetime(2026, 2, 1, 14, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time,
        sample_count=30,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    override = OverrideSpan(
        started_at=points[10].recorded_at,
        ended_at=points[19].recorded_at,
        motion_state="lift",
        created_by="user",
    )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[override],
        )
    )

    runs = [a for a in result.actions if a.action_type == "run"]
    lifts = [a for a in result.actions if a.action_type == "lift"]
    assert len(runs) == 2
    assert len(lifts) == 1


# ---------------------------------------------------------------------------
# Action-type vocabulary
# ---------------------------------------------------------------------------


def test_emitted_actions_only_run_or_lift() -> None:
    base_time = datetime(2026, 2, 1, 15, 0, 0, tzinfo=UTC)
    descent = _build_linear_descent(
        base_time=base_time,
        sample_count=15,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    uphill_start_time = descent[-1].recorded_at + timedelta(seconds=1)
    uphill = []
    for i in range(15):
        uphill.append(
            RawPoint(
                t_offset_ms=descent[-1].t_offset_ms + (i + 1) * 1000,
                recorded_at=uphill_start_time + timedelta(seconds=i),
                latitude=descent[-1].latitude + (i + 1) * 0.00005,
                longitude=descent[-1].longitude,
                altitude_m=descent[-1].altitude_m + (i + 1) * 2.0,
                speed_mps=3.0,
                accuracy_m=5.0,
            )
        )
    points = descent + uphill
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )
    types = {action.action_type for action in result.actions}
    assert types <= {"run", "lift"}
    assert "run" in types
    assert "lift" in types


# ---------------------------------------------------------------------------
# Peak altitude comes from actions, not raw-point max
# ---------------------------------------------------------------------------


def test_peak_altitude_uses_action_max_not_flyaway_raw_point() -> None:
    base_time = datetime(2026, 2, 1, 16, 0, 0, tzinfo=UTC)
    points = _build_linear_descent(
        base_time=base_time,
        sample_count=15,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
        start_altitude_m=1200.0,
    )
    # Inject a stationary flyaway point at a much higher altitude; stationary
    # speed keeps it out of any action span.
    flyaway = RawPoint(
        t_offset_ms=points[-1].t_offset_ms + 5000,
        recorded_at=points[-1].recorded_at + timedelta(seconds=5),
        latitude=points[-1].latitude + 0.0001,
        longitude=points[-1].longitude,
        altitude_m=4000.0,
        speed_mps=0.0,
        accuracy_m=5.0,
    )
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=[*points, flyaway],
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=flyaway.recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )
    assert result.summary.peak_altitude_m is not None
    # The raw flyaway point is 4000 m but never lands in an action span;
    # the action's max altitude (1190 m at sample 1, since sample 0 is
    # ignore) is the correct peak.
    assert result.summary.peak_altitude_m < 1500.0
    assert result.summary.peak_altitude_m == pytest.approx(1190.0, abs=ALTITUDE_ABS)


# ---------------------------------------------------------------------------
# Mid-action smoothing
# ---------------------------------------------------------------------------


def test_mid_action_smoothing_absorbs_short_ignore_span() -> None:
    base_time = datetime(2026, 2, 1, 17, 0, 0, tzinfo=UTC)
    first_leg = _build_linear_descent(
        base_time=base_time,
        sample_count=10,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    # 8 stationary low-speed samples — duration 7s (well under 360 s cap).
    ignore_samples: list[RawPoint] = []
    for i in range(8):
        ignore_samples.append(
            RawPoint(
                t_offset_ms=first_leg[-1].t_offset_ms + (i + 1) * 1000,
                recorded_at=first_leg[-1].recorded_at + timedelta(seconds=i + 1),
                latitude=first_leg[-1].latitude,
                longitude=first_leg[-1].longitude,
                altitude_m=first_leg[-1].altitude_m,
                speed_mps=0.0,
                accuracy_m=5.0,
            )
        )
    second_leg_start_time = ignore_samples[-1].recorded_at + timedelta(seconds=1)
    second_leg: list[RawPoint] = []
    for i in range(10):
        second_leg.append(
            RawPoint(
                t_offset_ms=ignore_samples[-1].t_offset_ms + (i + 1) * 1000,
                recorded_at=second_leg_start_time + timedelta(seconds=i),
                latitude=ignore_samples[-1].latitude + (i + 1) * 0.00009,
                longitude=ignore_samples[-1].longitude,
                altitude_m=ignore_samples[-1].altitude_m - (i + 1) * 10.0,
                speed_mps=10.0,
                accuracy_m=5.0,
            )
        )
    points = first_leg + ignore_samples + second_leg
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )
    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 1
    run = runs[0]
    # Wall-clock duration spans the whole range (>= both legs + ignore bridge).
    assert run.duration_s >= 20.0
    # Average speed excludes the zero-speed interval; smoothed endpoints get
    # diluted but the mean must stay well above 5 m/s.
    assert run.avg_speed_mps > 5.0


def test_mid_action_smoothing_does_not_absorb_long_ignore_span() -> None:
    base_time = datetime(2026, 2, 1, 18, 0, 0, tzinfo=UTC)
    first_leg = _build_linear_descent(
        base_time=base_time,
        sample_count=10,
        speed_mps=10.0,
        altitude_drop_per_sample_m=10.0,
    )
    # 720 s of ignore — 12 minutes, far above the 360 s cap.
    ignore_samples: list[RawPoint] = []
    ignore_start_time = first_leg[-1].recorded_at + timedelta(seconds=1)
    ignore_count = 720
    for i in range(ignore_count):
        ignore_samples.append(
            RawPoint(
                t_offset_ms=first_leg[-1].t_offset_ms + (i + 1) * 1000,
                recorded_at=ignore_start_time + timedelta(seconds=i),
                latitude=first_leg[-1].latitude,
                longitude=first_leg[-1].longitude,
                altitude_m=first_leg[-1].altitude_m,
                speed_mps=0.0,
                accuracy_m=5.0,
            )
        )
    second_leg_start_time = ignore_samples[-1].recorded_at + timedelta(seconds=1)
    second_leg: list[RawPoint] = []
    for i in range(10):
        second_leg.append(
            RawPoint(
                t_offset_ms=ignore_samples[-1].t_offset_ms + (i + 1) * 1000,
                recorded_at=second_leg_start_time + timedelta(seconds=i),
                latitude=ignore_samples[-1].latitude + (i + 1) * 0.00009,
                longitude=ignore_samples[-1].longitude,
                altitude_m=ignore_samples[-1].altitude_m - (i + 1) * 10.0,
                speed_mps=10.0,
                accuracy_m=5.0,
            )
        )
    points = first_leg + ignore_samples + second_leg
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    result = analyzer.analyze(
        AnalyzerInput(
            points=points,
            metadata=_base_metadata(
                record_start=points[0].recorded_at,
                record_end=points[-1].recorded_at,
                source="live_recording",
            ),
            preset_actions=None,
            preset_overrides=[],
        )
    )
    runs = [a for a in result.actions if a.action_type == "run"]
    assert len(runs) == 2


# ---------------------------------------------------------------------------
# Validation — bad input
# ---------------------------------------------------------------------------


def test_invalid_record_window_raises_validation_error() -> None:
    analyzer = SessionAnalyzer(analyzer_version=_TEST_ANALYZER_VERSION)
    metadata = SessionMetadataInput(
        record_start=datetime(2026, 2, 1, 19, 0, 0, tzinfo=UTC),
        record_end=datetime(2026, 2, 1, 18, 0, 0, tzinfo=UTC),
        resort_id=uuid.uuid4(),
        source="live_recording",
    )
    with pytest.raises(ValidationError):
        analyzer.analyze(
            AnalyzerInput(
                points=[],
                metadata=metadata,
                preset_actions=None,
                preset_overrides=[],
            )
        )
