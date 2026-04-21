"""Pure session analyzer service.

Turns raw capture input (live path) or pre-aggregated action rows
(import path) into a canonical `AnalysisResult`. No database access
and no HTTP exceptions — bad input raises `ValidationError`.

The algorithm contract is owned by Step 4 of the Slopes-parity rebuild
plan; numeric knobs below are module-level so they can be tuned without
touching call sites.
"""

from __future__ import annotations

from collections.abc import Iterable
from collections.abc import Sequence
from dataclasses import dataclass
from dataclasses import field
from datetime import datetime
import math
import uuid

from app.services.exceptions import ValidationError

# -----------------------------------------------------------------------------
# Tunables
#
# Every constant below is module-level so a future PR can tune it in one place.
# Provenance tags:
#   [plan]     — pinned by plans/slopes_parity_rebuild_plan.md, do not change
#                without an explicit plan amendment.
#   [port]     — 1:1 port of a numeric threshold from the current mobile
#                session pipeline. Mobile owns the original; this copy becomes
#                the backend truth after Step 11 deletes the mobile version.
#   [default]  — placeholder chosen here because neither the plan nor the
#                mobile code pins a value. Tagged with the step that should
#                revisit it once real data exists.
# -----------------------------------------------------------------------------

# [plan] Step 4 sub-step 2. Centered rolling mean over N samples — operates
# on sample indices, not wall-clock time. **Revisit in Step 8** (Motion-
# adaptive sampling): when capture drops to 0.04 Hz in idle profile, this
# 5-sample window becomes a 125-second smoother and will blur real speed
# transitions at the start/end of lifts. Step 8 carries the
# "Analyzer-compatibility goal" that converts this to a time-based window
# (or deletes the constant entirely, in favor of a ±2.5 s wall-clock span).
# Until Step 8 lands, all live-path recordings must stay at ≥ 1 Hz.
SPEED_SMOOTHING_WINDOW = 5

# [plan] Step 4 sub-step 4a. Explicitly a tuning knob per the plan; tune in
# one place, re-run tests/unit/test_session_analyzer.py.
MAX_MID_ACTION_IGNORE_S = 360

# [plan] Step 4 sub-step 7.
MIN_ACTION_DURATION_S = 2.0

# [default] No pinned value in the plan. 50 m is a placeholder chosen to
# tolerate consumer-GPS horizontal error plus vertex-sparse polylines.
# **Revisit in Part 3 Marker #3** (Resort lift catalog population) — not
# Step 7. Step 7 imports Slopes archives but explicitly defers resort_lifts
# population to Marker #3. The Marker #3 entry covers both the radius
# retune and the mid-action classification invariant the populated catalog
# makes enforceable (classifier precedence + short-blip absorber).
LIFT_MATCH_RADIUS_M = 50.0

# [port] mobile/lib/core/constants/session_constants.dart — stoppedSpeedThresholdMetersPerSecond.
STOPPED_SPEED_MPS = 0.8

# [port] mobile session_constants.dart — liftMinSpeedThresholdMetersPerSecond.
LIFT_MIN_SPEED_MPS = 1.2

# [tuned] Raised from the mobile-ported 8.0 to 10.0 to cover aerial trams
# and the fastest gondolas (Jackson Hole, Palisades, Zermatt, Zugspitze all
# run at ~10 m/s). Detachable quads top out at ~5 m/s, so the middle of the
# band is unchanged; this only widens the ceiling. The cap still matters:
# it prevents fast descents (which hit 12-15 m/s on expert terrain) from
# being mis-labeled as lift if altitude noise transiently points up.
# **Revalidate in Step 12** (Post-deletion analyzer-constant revalidation).
LIFT_MAX_SPEED_MPS = 10.0

# [tuned] Lowered from the mobile-ported 4.0 to 2.0 during Step 4. Part 0
# line 147 explicitly flags the mobile 4.0 as "classifies slow-glide
# sections as idle" — cat-tracks, green-run carves, and traverses between
# runs all cruise in the 2-4 m/s band and were being dropped into `ignore`.
# 2.0 captures them while leaving a 0.8 m/s buffer above LIFT_MIN_SPEED_MPS
# (1.2), so the `[1.2, 2.0)` ambiguous band — where altitude-noise sign
# alone would decide lift vs. run — stays masked as ignore rather than
# coin-flipping. **Revalidate in Step 12** (Post-deletion analyzer-constant
# revalidation) against real live-path dev sessions once the mobile
# pipeline is deleted. Step 11 is where you'd run the reanalyze script
# that produces the data for that validation.
DESCENT_SPEED_MPS = 2.0

# [port] mobile/lib/features/session/domain/pipeline/motion_state_detector.dart —
# absolute per-sample altitude deltas for lift-climb / run-descend.
LIFT_CLIMB_DELTA_M = 0.6
RUN_DESCEND_DELTA_M = -0.6

# [tuned] GPS-speed-spike rejection for per-action `max_speed_mps` and
# `top_speed_*` on the live path. A raw speed sample is treated as a
# plausible peak when it is within `SPIKE_RATIO` of its smoothed
# counterpart. A legitimate sharp peak has smoothing tracking within
# ~1.1-1.3× because the centered mean sees the build-up on both sides;
# a one-sample GPS pathology (multipath, Kalman hiccup) sits at ratio
# ≥ 2.5 because 4/5 of the smoother's window are flat neighbors.
# `SPIKE_RATIO_REFERENCE_FLOOR_MPS` is the denominator floor so the
# filter degrades gracefully when smoothed is near zero at action
# start; below the floor, only `raw ≤ 2.0 m/s` passes, which is below
# anything interesting anyway. **Revalidate in Step 12** alongside the
# remaining quality_classifier port decision.
SPIKE_RATIO = 2.0
SPIKE_RATIO_REFERENCE_FLOOR_MPS = 1.0

# [tuned] Tightened from an initial 50 m placeholder to 30 m during Step 4.
# Mobile's deleted quality_classifier.dart used a three-tier cascade
# (25 m strong / 35 m accept / 80 m low-confidence) plus implausible-jump,
# speed-spike, timestamp-monotonicity, and platform-speed-trust gates.
# 30 m sits between the mobile "strong" and "accept" tiers and matches
# the loose-reject cutoff used by Garmin/Fitbit. Open-sky smartphone GPS
# is 3-8 m; lift-tower and tree-cover degrade to 10-30 m legitimately;
# anything worse than 30 m is a ~40 m teleport per sample that would
# 4x speed estimates on a single tick, which smoothing mitigates but
# does not eliminate. **Revalidate in Step 12** (Post-deletion analyzer-
# constant revalidation) by watching the Step 12 structured-log rejection
# rate on real live sessions; port mobile's three-tier cascade back if
# rejection climbs above a few percent under lift-tower/tree cover.
ACCURACY_REJECT_M = 30.0

# Mean Earth radius — standard constant for haversine distance.
_EARTH_RADIUS_M = 6_371_000.0

RUN = "run"
LIFT = "lift"
IGNORE = "ignore"
_LIVE_SOURCE = "live_analyzer"
_IMPORT_SOURCE = "slopes_import"


@dataclass(frozen=True)
class RawPoint:
    t_offset_ms: int
    recorded_at: datetime
    latitude: float
    longitude: float
    altitude_m: float | None
    speed_mps: float | None
    accuracy_m: float | None = None
    vertical_accuracy_m: float | None = None


@dataclass(frozen=True)
class SessionMetadataInput:
    record_start: datetime
    record_end: datetime
    resort_id: uuid.UUID | None
    source: str


@dataclass(frozen=True)
class PresetAction:
    action_type: str
    sequence_index: int
    started_at: datetime
    ended_at: datetime
    duration_s: float
    distance_m: float
    avg_speed_mps: float
    max_speed_mps: float
    min_speed_mps: float | None = None
    vertical_m: float | None = None
    min_altitude_m: float | None = None
    max_altitude_m: float | None = None
    min_lat: float | None = None
    max_lat: float | None = None
    min_long: float | None = None
    max_long: float | None = None
    top_speed_lat: float | None = None
    top_speed_long: float | None = None
    top_speed_alt_m: float | None = None
    time_of_day: int | None = None
    external_track_id: str | None = None


@dataclass(frozen=True)
class OverrideSpan:
    started_at: datetime
    ended_at: datetime
    motion_state: str
    created_by: str


@dataclass(frozen=True)
class ResortLift:
    name: str
    polyline: Sequence[tuple[float, float]]
    lift_type: str | None = None


@dataclass(frozen=True)
class ActionRecord:
    action_type: str
    sequence_index: int
    started_at: datetime
    ended_at: datetime
    duration_s: float
    distance_m: float
    avg_speed_mps: float
    max_speed_mps: float
    min_speed_mps: float | None
    vertical_m: float | None
    min_altitude_m: float | None
    max_altitude_m: float | None
    min_lat: float | None
    max_lat: float | None
    min_long: float | None
    max_long: float | None
    top_speed_lat: float | None
    top_speed_long: float | None
    top_speed_alt_m: float | None
    time_of_day: int | None
    external_track_id: str | None
    source: str


@dataclass(frozen=True)
class OverrideRecord:
    started_at: datetime
    ended_at: datetime
    motion_state: str
    created_by: str


@dataclass(frozen=True)
class SessionSummaryFields:
    total_duration_s: float
    descent_duration_s: float
    lift_duration_s: float
    descent_distance_m: float
    lift_distance_m: float
    descent_vertical_m: float
    lift_vertical_m: float
    max_speed_mps: float | None
    avg_descent_speed_mps: float | None
    peak_altitude_m: float | None
    center_lat: float | None
    center_long: float | None
    altitude_offset_m: float


@dataclass(frozen=True)
class AnalyzerInput:
    points: list[RawPoint]
    metadata: SessionMetadataInput
    preset_actions: list[PresetAction] | None = None
    preset_overrides: list[OverrideSpan] | None = None
    resort_lifts: Sequence[ResortLift] = field(default_factory=tuple)


@dataclass(frozen=True)
class AnalysisResult:
    summary: SessionSummaryFields
    actions: list[ActionRecord]
    overrides: list[OverrideRecord]
    analyzer_version: str


class SessionAnalyzer:
    """Pure analyzer. Call `analyze(input)` to produce an `AnalysisResult`.

    `analyzer_version` is injected at construction — the analyzer does not
    reach into `app.core.config` itself, keeping the service pure and
    test-isolated from settings state.
    """

    def __init__(self, *, analyzer_version: str) -> None:
        self._analyzer_version = analyzer_version

    def analyze(self, analyzer_input: AnalyzerInput) -> AnalysisResult:
        _validate_input(analyzer_input)

        overrides = list(analyzer_input.preset_overrides or ())
        override_records = [_override_to_record(span) for span in overrides]

        if analyzer_input.preset_actions:
            actions = _actions_from_preset(analyzer_input.preset_actions)
        else:
            actions = _actions_from_points(
                analyzer_input.points,
                overrides=overrides,
                resort_lifts=analyzer_input.resort_lifts,
            )

        summary = _summary_from_actions(
            actions=actions,
            metadata=analyzer_input.metadata,
        )

        return AnalysisResult(
            summary=summary,
            actions=actions,
            overrides=override_records,
            analyzer_version=self._analyzer_version,
        )


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def _validate_input(analyzer_input: AnalyzerInput) -> None:
    metadata = analyzer_input.metadata
    if metadata.record_end < metadata.record_start:
        raise ValidationError("record_end must be >= record_start")

    preset_actions = analyzer_input.preset_actions or []
    for preset in preset_actions:
        if preset.action_type not in (RUN, LIFT):
            raise ValidationError(
                f"Preset action type must be 'run' or 'lift', got: {preset.action_type!r}"
            )
        if preset.ended_at < preset.started_at:
            raise ValidationError("Preset action ended_at must be >= started_at")

    for span in analyzer_input.preset_overrides or []:
        if span.motion_state not in (RUN, LIFT, IGNORE):
            raise ValidationError(
                f"Override motion_state must be run/lift/ignore, got: {span.motion_state!r}"
            )
        if span.ended_at < span.started_at:
            raise ValidationError("Override ended_at must be >= started_at")


# ---------------------------------------------------------------------------
# Import path
# ---------------------------------------------------------------------------


def _actions_from_preset(preset_actions: Sequence[PresetAction]) -> list[ActionRecord]:
    ordered = sorted(preset_actions, key=lambda a: (a.action_type, a.sequence_index))
    return [
        ActionRecord(
            action_type=preset.action_type,
            sequence_index=preset.sequence_index,
            started_at=preset.started_at,
            ended_at=preset.ended_at,
            duration_s=float(preset.duration_s),
            distance_m=float(preset.distance_m),
            avg_speed_mps=float(preset.avg_speed_mps),
            max_speed_mps=float(preset.max_speed_mps),
            min_speed_mps=_opt_float(preset.min_speed_mps),
            vertical_m=_opt_float(preset.vertical_m),
            min_altitude_m=_opt_float(preset.min_altitude_m),
            max_altitude_m=_opt_float(preset.max_altitude_m),
            min_lat=_opt_float(preset.min_lat),
            max_lat=_opt_float(preset.max_lat),
            min_long=_opt_float(preset.min_long),
            max_long=_opt_float(preset.max_long),
            top_speed_lat=_opt_float(preset.top_speed_lat),
            top_speed_long=_opt_float(preset.top_speed_long),
            top_speed_alt_m=_opt_float(preset.top_speed_alt_m),
            time_of_day=preset.time_of_day,
            external_track_id=preset.external_track_id,
            source=_IMPORT_SOURCE,
        )
        for preset in ordered
    ]


# ---------------------------------------------------------------------------
# Live path
# ---------------------------------------------------------------------------


@dataclass
class _Sample:
    """Per-sample scratchpad used only inside the live-path pipeline."""

    index: int
    t_offset_ms: int
    recorded_at: datetime
    latitude: float
    longitude: float
    altitude_m: float | None
    raw_speed_mps: float | None
    smoothed_speed_mps: float
    state: str
    masked: bool = False


def _actions_from_points(
    raw_points: Sequence[RawPoint],
    *,
    overrides: Sequence[OverrideSpan],
    resort_lifts: Sequence[ResortLift],
) -> list[ActionRecord]:
    accepted = _accuracy_filter(raw_points)
    if not accepted:
        return []

    smoothed_speeds = smooth_speeds_centered_mean(
        [p.speed_mps if p.speed_mps is not None else 0.0 for p in accepted]
    )

    samples: list[_Sample] = []
    lift_vertices = _flatten_lift_vertices(resort_lifts)
    use_spatial = bool(lift_vertices)
    prev_altitude: float | None = None

    for index, (point, smoothed) in enumerate(zip(accepted, smoothed_speeds, strict=True)):
        vertical_delta_m = (
            None
            if point.altitude_m is None or prev_altitude is None
            else point.altitude_m - prev_altitude
        )
        state = _classify_point(
            latitude=point.latitude,
            longitude=point.longitude,
            smoothed_speed_mps=smoothed,
            vertical_delta_m=vertical_delta_m,
            lift_vertices=lift_vertices,
            use_spatial=use_spatial,
        )
        samples.append(
            _Sample(
                index=index,
                t_offset_ms=point.t_offset_ms,
                recorded_at=point.recorded_at,
                latitude=point.latitude,
                longitude=point.longitude,
                altitude_m=point.altitude_m,
                raw_speed_mps=point.speed_mps,
                smoothed_speed_mps=smoothed,
                state=state,
            )
        )
        if point.altitude_m is not None:
            prev_altitude = point.altitude_m

    _absorb_mid_action_ignores(samples)
    _apply_preset_overrides(samples, overrides)

    spans = _collapse_into_spans(samples)
    spans = [s for s in spans if _duration_s(s[0].recorded_at, s[-1].recorded_at) >= MIN_ACTION_DURATION_S]

    actions: list[ActionRecord] = []
    run_seq = 0
    lift_seq = 0
    for span in spans:
        state = span[0].state
        if state == RUN:
            run_seq += 1
            sequence_index = run_seq
        else:
            lift_seq += 1
            sequence_index = lift_seq
        actions.append(_build_action_record(span, sequence_index=sequence_index))

    return actions


def _accuracy_filter(raw_points: Sequence[RawPoint]) -> list[RawPoint]:
    # Single-cutoff horizontal-accuracy reject. The mobile
    # `quality_classifier.dart` deleted in Step 11 had three additional
    # gates: implausible-jump, speed-spike, and timestamp-monotonicity.
    # A GPS fix with good horizontal accuracy but a pathological speed
    # field (rare but real on some consumer phones) will slip through
    # today and can inflate `max_speed_mps` on the live path. **Revisit
    # in Step 12** (Post-deletion analyzer-constant revalidation) — the
    # decision to port the full cascade back vs. stay on a single cutoff
    # belongs with that block's observability data, not here.
    accepted: list[RawPoint] = []
    for point in raw_points:
        if point.accuracy_m is not None and point.accuracy_m > ACCURACY_REJECT_M:
            continue
        accepted.append(point)
    return accepted


def smooth_speeds_centered_mean(speeds: Sequence[float]) -> list[float]:
    """Centered rolling mean with window=5 and edge padding by boundary repeat."""
    if not speeds:
        return []
    window = SPEED_SMOOTHING_WINDOW
    half = window // 2
    n = len(speeds)
    out: list[float] = []
    for i in range(n):
        total = 0.0
        for k in range(-half, half + 1):
            j = i + k
            if j < 0:
                j = 0
            elif j >= n:
                j = n - 1
            total += float(speeds[j])
        out.append(total / window)
    return out


def _flatten_lift_vertices(
    resort_lifts: Sequence[ResortLift],
) -> list[tuple[float, float]]:
    vertices: list[tuple[float, float]] = []
    for lift in resort_lifts:
        for vertex in lift.polyline:
            vertices.append((float(vertex[0]), float(vertex[1])))
    return vertices


def _classify_point(
    *,
    latitude: float,
    longitude: float,
    smoothed_speed_mps: float,
    vertical_delta_m: float | None,
    lift_vertices: Sequence[tuple[float, float]],
    use_spatial: bool,
) -> str:
    if use_spatial and _within_lift_radius(latitude, longitude, lift_vertices):
        return LIFT

    if smoothed_speed_mps < STOPPED_SPEED_MPS:
        return IGNORE

    in_lift_band = LIFT_MIN_SPEED_MPS <= smoothed_speed_mps <= LIFT_MAX_SPEED_MPS
    if (
        in_lift_band
        and vertical_delta_m is not None
        and vertical_delta_m > LIFT_CLIMB_DELTA_M
    ):
        return LIFT

    if (
        smoothed_speed_mps >= DESCENT_SPEED_MPS
        and vertical_delta_m is not None
        and vertical_delta_m < RUN_DESCEND_DELTA_M
    ):
        return RUN

    return IGNORE


def _within_lift_radius(
    latitude: float,
    longitude: float,
    vertices: Sequence[tuple[float, float]],
) -> bool:
    for vlat, vlong in vertices:
        if _haversine_m(latitude, longitude, vlat, vlong) <= LIFT_MATCH_RADIUS_M:
            return True
    return False


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * _EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def _absorb_mid_action_ignores(samples: list[_Sample]) -> None:
    spans = _find_state_spans(samples)
    for idx in range(1, len(spans) - 1):
        prev_state, _, _ = spans[idx - 1]
        this_state, start, end = spans[idx]
        next_state, _, _ = spans[idx + 1]
        if this_state != IGNORE:
            continue
        if prev_state != next_state:
            continue
        if prev_state not in (RUN, LIFT):
            continue
        duration = _duration_s(samples[start].recorded_at, samples[end].recorded_at)
        if duration > MAX_MID_ACTION_IGNORE_S:
            continue
        # Bridge the gap inside the enclosing action but keep the low-speed
        # samples out of the per-action stats (avgSpeed / distance) — the
        # wall-clock duration still spans the whole range.
        for i in range(start, end + 1):
            samples[i].state = prev_state
            samples[i].masked = True


def _find_state_spans(samples: Sequence[_Sample]) -> list[tuple[str, int, int]]:
    spans: list[tuple[str, int, int]] = []
    if not samples:
        return spans
    start = 0
    for i in range(1, len(samples)):
        if samples[i].state != samples[start].state:
            spans.append((samples[start].state, start, i - 1))
            start = i
    spans.append((samples[start].state, start, len(samples) - 1))
    return spans


def _apply_preset_overrides(
    samples: list[_Sample],
    overrides: Sequence[OverrideSpan],
) -> None:
    for span in overrides:
        for sample in samples:
            if span.started_at <= sample.recorded_at <= span.ended_at:
                if span.motion_state == IGNORE:
                    sample.masked = True
                else:
                    sample.state = span.motion_state
                    sample.masked = False


def _collapse_into_spans(samples: Sequence[_Sample]) -> list[list[_Sample]]:
    groups: list[list[_Sample]] = []
    current: list[_Sample] = []
    current_state: str | None = None
    for sample in samples:
        if sample.state == IGNORE:
            if current:
                groups.append(current)
                current = []
                current_state = None
            continue
        if current_state is None or sample.state == current_state:
            current.append(sample)
            current_state = sample.state
        else:
            groups.append(current)
            current = [sample]
            current_state = sample.state
    if current:
        groups.append(current)
    return groups


def _is_plausible_raw_speed(sample: _Sample) -> bool:
    if sample.raw_speed_mps is None:
        return False
    reference = max(sample.smoothed_speed_mps, SPIKE_RATIO_REFERENCE_FLOOR_MPS)
    return sample.raw_speed_mps <= reference * SPIKE_RATIO


def _build_action_record(span: list[_Sample], *, sequence_index: int) -> ActionRecord:
    state = span[0].state
    started_at = span[0].recorded_at
    ended_at = span[-1].recorded_at
    duration_s = _duration_s(started_at, ended_at)

    contributing = [s for s in span if not s.masked]
    stat_samples = contributing if contributing else list(span)

    distance_m = _span_distance_m(stat_samples)

    # Avg and min use smoothed speeds (noise-robust; close to Slopes' avgSpeed
    # for uniform 1 Hz sampling). Max and top_speed_* use RAW speeds — the
    # smoother biases peaks downward and would under-report a rider's top
    # speed by 2-4 m/s on a 5-sample window. This matches Slopes' topSpeed
    # semantics on the import path and keeps the two paths symmetric.
    smoothed_speeds = [s.smoothed_speed_mps for s in stat_samples]
    avg_speed = sum(smoothed_speeds) / len(smoothed_speeds) if smoothed_speeds else 0.0
    min_speed = min(smoothed_speeds) if smoothed_speeds else None

    raw_speed_samples = [s for s in stat_samples if _is_plausible_raw_speed(s)]
    max_speed = (
        max(s.raw_speed_mps for s in raw_speed_samples) if raw_speed_samples else 0.0
    )
    top_sample = (
        max(raw_speed_samples, key=lambda s: s.raw_speed_mps)
        if raw_speed_samples
        else None
    )
    top_speed_lat = top_sample.latitude if top_sample is not None else None
    top_speed_long = top_sample.longitude if top_sample is not None else None
    top_speed_alt_m = (
        top_sample.altitude_m if top_sample is not None and top_sample.altitude_m is not None else None
    )

    altitudes = [s.altitude_m for s in stat_samples if s.altitude_m is not None]
    min_altitude_m = min(altitudes) if altitudes else None
    max_altitude_m = max(altitudes) if altitudes else None
    vertical_m: float | None
    if max_altitude_m is not None and min_altitude_m is not None:
        vertical_m = max_altitude_m - min_altitude_m
    else:
        vertical_m = None

    lats = [s.latitude for s in stat_samples]
    longs = [s.longitude for s in stat_samples]

    return ActionRecord(
        action_type=state,
        sequence_index=sequence_index,
        started_at=started_at,
        ended_at=ended_at,
        duration_s=duration_s,
        distance_m=distance_m,
        avg_speed_mps=avg_speed,
        max_speed_mps=max_speed,
        min_speed_mps=min_speed,
        vertical_m=vertical_m,
        min_altitude_m=min_altitude_m,
        max_altitude_m=max_altitude_m,
        min_lat=min(lats) if lats else None,
        max_lat=max(lats) if lats else None,
        min_long=min(longs) if longs else None,
        max_long=max(longs) if longs else None,
        top_speed_lat=top_speed_lat,
        top_speed_long=top_speed_long,
        top_speed_alt_m=top_speed_alt_m,
        time_of_day=None,
        external_track_id=None,
        source=_LIVE_SOURCE,
    )


def _span_distance_m(samples: Sequence[_Sample]) -> float:
    if len(samples) < 2:
        return 0.0
    total = 0.0
    prev = samples[0]
    for curr in samples[1:]:
        total += _haversine_m(prev.latitude, prev.longitude, curr.latitude, curr.longitude)
        prev = curr
    return total


# ---------------------------------------------------------------------------
# Summary assembly
# ---------------------------------------------------------------------------


def _summary_from_actions(
    *,
    actions: Sequence[ActionRecord],
    metadata: SessionMetadataInput,
) -> SessionSummaryFields:
    total_duration_s = _duration_s(metadata.record_start, metadata.record_end)

    runs = [a for a in actions if a.action_type == RUN]
    lifts = [a for a in actions if a.action_type == LIFT]

    descent_duration_s = sum(a.duration_s for a in runs)
    lift_duration_s = sum(a.duration_s for a in lifts)
    descent_distance_m = sum(a.distance_m for a in runs)
    lift_distance_m = sum(a.distance_m for a in lifts)
    descent_vertical_m = sum((a.vertical_m or 0.0) for a in runs)
    lift_vertical_m = sum((a.vertical_m or 0.0) for a in lifts)

    max_speed_mps = max((a.max_speed_mps for a in runs), default=None)
    avg_descent_speed_mps = (
        sum(a.avg_speed_mps for a in runs) / len(runs) if runs else None
    )

    per_action_peaks = [a.max_altitude_m for a in actions if a.max_altitude_m is not None]
    peak_altitude_m = max(per_action_peaks) if per_action_peaks else None

    center_lat, center_long = _bbox_center(actions)

    return SessionSummaryFields(
        total_duration_s=total_duration_s,
        descent_duration_s=descent_duration_s,
        lift_duration_s=lift_duration_s,
        descent_distance_m=descent_distance_m,
        lift_distance_m=lift_distance_m,
        descent_vertical_m=descent_vertical_m,
        lift_vertical_m=lift_vertical_m,
        max_speed_mps=max_speed_mps,
        avg_descent_speed_mps=avg_descent_speed_mps,
        peak_altitude_m=peak_altitude_m,
        center_lat=center_lat,
        center_long=center_long,
        altitude_offset_m=0.0,
    )


def _bbox_center(actions: Iterable[ActionRecord]) -> tuple[float | None, float | None]:
    lats: list[float] = []
    longs: list[float] = []
    for action in actions:
        if action.min_lat is not None:
            lats.append(action.min_lat)
        if action.max_lat is not None:
            lats.append(action.max_lat)
        if action.min_long is not None:
            longs.append(action.min_long)
        if action.max_long is not None:
            longs.append(action.max_long)
    if not lats or not longs:
        return None, None
    return (min(lats) + max(lats)) / 2.0, (min(longs) + max(longs)) / 2.0


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def _duration_s(start: datetime, end: datetime) -> float:
    return (end - start).total_seconds()


def _opt_float(value: float | None) -> float | None:
    return None if value is None else float(value)


def _override_to_record(span: OverrideSpan) -> OverrideRecord:
    return OverrideRecord(
        started_at=span.started_at,
        ended_at=span.ended_at,
        motion_state=span.motion_state,
        created_by=span.created_by,
    )


__all__ = [
    "ActionRecord",
    "AnalysisResult",
    "AnalyzerInput",
    "LIFT",
    "LIFT_MATCH_RADIUS_M",
    "MAX_MID_ACTION_IGNORE_S",
    "MIN_ACTION_DURATION_S",
    "OverrideRecord",
    "OverrideSpan",
    "PresetAction",
    "RUN",
    "IGNORE",
    "RawPoint",
    "ResortLift",
    "SessionAnalyzer",
    "SessionMetadataInput",
    "SessionSummaryFields",
    "smooth_speeds_centered_mean",
]
