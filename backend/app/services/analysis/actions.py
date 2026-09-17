"""Turn decoded per-second states into run and lift actions (spec section 8)."""

from __future__ import annotations

from collections.abc import Iterable
from collections.abc import Sequence
from dataclasses import dataclass

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import haversine_m
from app.services.analysis.hmm import State
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import FeatureFrame
from app.services.analysis.types import IGNORE
from app.services.analysis.types import LIFT
from app.services.analysis.types import LIVE_SOURCE
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import SessionMetadataInput
from app.services.analysis.types import SessionSummaryFields

Area = tuple[float, float, float, float]
Span = tuple[State, int, int]


@dataclass(frozen=True)
class BreakStats:
    count: int
    duration_s: float


def build(
    frame: FeatureFrame,
    states: Sequence[State],
    anchored: Sequence[LiftSpan],
    overrides: Sequence[OverrideSpan],
    config: AnalyzerConfig,
    *,
    area: Area | None,
) -> tuple[list[ActionRecord], BreakStats]:
    n = len(frame)
    st = list(states)
    locked = [False] * n
    masked = [False] * n
    for span in anchored:
        for i in range(max(0, span.start), min(n - 1, span.end) + 1):
            locked[i] = True
    _apply_overrides(frame, st, locked, masked, overrides)
    _demote_tiny_descents(frame, st, locked, config)
    _demote_weak_fallback_lifts(frame, st, locked, area, config)
    _merge_lift_stoppages(frame, st, config)

    lifts = [(a, b) for state, a, b in _spans(st) if state == State.LIFT]
    _invalidate_descents(frame, st, locked, lifts, area, config)
    runs = _assemble_runs(frame, st, config)

    for run_start, run_end in runs:
        for state, a, b in _spans(st[run_start : run_end + 1]):
            if state == State.STOP and (b - a + 1) >= config.long_stop_s:
                for i in range(run_start + a, run_start + b + 1):
                    masked[i] = True

    timeline = sorted([(a, b, RUN) for a, b in runs] + [(a, b, LIFT) for a, b in lifts])
    actions: list[ActionRecord] = []
    counters = {RUN: 0, LIFT: 0}
    for a, b, kind in timeline:
        if (b - a) < config.min_action_duration_s:
            continue
        counters[kind] += 1
        name, track_id = _lift_identity(anchored, a, b) if kind == LIFT else (None, None)
        actions.append(_record(frame, a, b, kind, counters[kind], masked, config, name, track_id))

    if not timeline:
        return actions, BreakStats(0, 0.0)
    return actions, break_stats(st, timeline[0][0], timeline[-1][1], config)


def break_stats(states: Sequence[State], lo: int, hi: int, config: AnalyzerConfig) -> BreakStats:
    count = 0
    total = 0.0
    lo = max(0, lo)
    hi = min(len(states) - 1, hi)
    for state, a, b in _spans(list(states[lo : hi + 1])):
        duration = b - a + 1
        if state == State.STOP and duration >= config.long_stop_s:
            count += 1
            total += float(duration)
    return BreakStats(count, total)


def summarize(
    actions: Sequence[ActionRecord], metadata: SessionMetadataInput, breaks: BreakStats
) -> SessionSummaryFields:
    runs = [a for a in actions if a.action_type == RUN]
    lifts = [a for a in actions if a.action_type == LIFT]
    peaks = [a.max_altitude_m for a in actions if a.max_altitude_m is not None]
    center_lat, center_long = _bbox_center(actions)
    return SessionSummaryFields(
        total_duration_s=(metadata.record_end - metadata.record_start).total_seconds(),
        descent_duration_s=sum(a.duration_s for a in runs),
        lift_duration_s=sum(a.duration_s for a in lifts),
        descent_distance_m=sum(a.distance_m for a in runs),
        lift_distance_m=sum(a.distance_m for a in lifts),
        descent_vertical_m=sum((a.vertical_m or 0.0) for a in runs),
        lift_vertical_m=sum((a.vertical_m or 0.0) for a in lifts),
        max_speed_mps=max((a.max_speed_mps for a in runs), default=None),
        avg_descent_speed_mps=(sum(a.avg_speed_mps for a in runs) / len(runs)) if runs else None,
        peak_altitude_m=max(peaks) if peaks else None,
        center_lat=center_lat,
        center_long=center_long,
        altitude_offset_m=0.0,
        break_count=breaks.count,
        break_duration_s=breaks.duration_s,
    )


# --------------------------------------------------------------------------- helpers


def _spans(states: Sequence[State]) -> list[Span]:
    out: list[Span] = []
    start = 0
    for i in range(1, len(states) + 1):
        if i == len(states) or states[i] != states[start]:
            out.append((states[start], start, i - 1))
            start = i
    return out if states else []


def _apply_overrides(
    frame: FeatureFrame,
    st: list[State],
    locked: list[bool],
    masked: list[bool],
    overrides: Sequence[OverrideSpan],
) -> None:
    frame_start, frame_end = frame.time_at(0), frame.time_at(len(frame) - 1)
    for span in overrides:
        if span.ended_at < frame_start or span.started_at > frame_end:
            continue
        lo, hi = frame.index_at(span.started_at), frame.index_at(span.ended_at)
        for i in range(lo, hi + 1):
            if span.motion_state == IGNORE:
                masked[i] = True
            else:
                st[i] = State.LIFT if span.motion_state == LIFT else State.DESCENT
                locked[i] = True
                masked[i] = False


def _demote_tiny_descents(
    frame: FeatureFrame, st: list[State], locked: Sequence[bool], config: AnalyzerConfig
) -> None:
    for state, a, b in _spans(st):
        if state != State.DESCENT or all(locked[a : b + 1]):
            continue
        if sum(frame.speed[a : b + 1]) < config.tiny_descent_m:
            st[a : b + 1] = [State.STOP] * (b - a + 1)


def _inside_area(frame: FeatureFrame, a: int, b: int, area: Area | None) -> bool:
    if area is None:
        return True
    min_lat, max_lat, min_lon, max_lon = area
    inside = sum(
        1
        for i in range(a, b + 1)
        if min_lat <= frame.lat[i] <= max_lat and min_lon <= frame.lon[i] <= max_lon
    )
    return inside >= 0.5 * (b - a + 1)


def _demote_weak_fallback_lifts(
    frame: FeatureFrame,
    st: list[State],
    locked: Sequence[bool],
    area: Area | None,
    config: AnalyzerConfig,
) -> None:
    n = len(st)
    i = 0
    while i < n:
        if st[i] != State.LIFT or locked[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and st[j + 1] == State.LIFT and not locked[j + 1]:
            j += 1
        speeds = sorted(frame.speed[i : j + 1])
        keep = (
            (j - i + 1) >= config.fallback_lift_min_s
            and (frame.alt[j] - frame.alt[i]) >= config.fallback_lift_min_gain_m
            and speeds[len(speeds) // 2] <= config.fallback_lift_max_median_mps
            and _inside_area(frame, i, j, area)
        )
        if not keep:
            st[i : j + 1] = [State.STOP] * (j - i + 1)
        i = j + 1


def _merge_lift_stoppages(frame: FeatureFrame, st: list[State], config: AnalyzerConfig) -> None:
    changed = True
    while changed:
        changed = False
        spans = _spans(st)
        for q in range(1, len(spans) - 1):
            state, a, b = spans[q]
            if state not in (State.STOP, State.UNKNOWN):
                continue
            if spans[q - 1][0] != State.LIFT or spans[q + 1][0] != State.LIFT:
                continue
            moved = haversine_m(frame.lat[a], frame.lon[a], frame.lat[b], frame.lon[b])
            if (
                b - a + 1
            ) <= config.lift_stoppage_max_s and moved <= config.lift_stoppage_max_move_m:
                st[a : b + 1] = [State.LIFT] * (b - a + 1)
                changed = True
                break


def _invalidate_descents(
    frame: FeatureFrame,
    st: list[State],
    locked: Sequence[bool],
    lifts: Sequence[tuple[int, int]],
    area: Area | None,
    config: AnalyzerConfig,
) -> None:
    # Only lifts ridden uphill define a base. After a gondola download the rider is in the
    # valley, which is still below every uphill base, so the drive home is caught as well.
    base_alt = min((frame.alt[a] for a, b in lifts if frame.alt[b] > frame.alt[a]), default=None)
    for state, a, b in _spans(st):
        if state != State.DESCENT or all(locked[a : b + 1]):
            continue
        duration = b - a + 1
        fast_seconds = sum(1 for v in frame.speed[a : b + 1] if v > config.vehicle_mps)
        mean_speed = sum(frame.speed[a : b + 1]) / duration
        flat_fast = (
            abs(frame.alt[b] - frame.alt[a]) < config.flat_fast_max_change_m
            and mean_speed > config.flat_fast_mps
            and duration >= config.flat_fast_min_s
        )
        below_base = base_alt is not None and frame.alt[a] < base_alt + config.base_margin_m
        if (
            fast_seconds >= config.vehicle_min_s
            or flat_fast
            or below_base
            or not _inside_area(frame, a, b, area)
        ):
            st[a : b + 1] = [State.INVALID] * duration


def _run_tail_drop_m(frame: FeatureFrame, spans: Sequence[Span], index: int) -> float:
    _, a, b = spans[index]
    return frame.alt[a] - frame.alt[b]


def _assemble_runs(
    frame: FeatureFrame, st: Sequence[State], config: AnalyzerConfig
) -> list[tuple[int, int]]:
    spans = _spans(st)
    moving = (State.DESCENT, State.INVALID)
    runs: list[tuple[int, int]] = []
    i = 0
    while i < len(spans):
        if spans[i][0] not in moving:
            i += 1
            continue
        chain = [i]
        j = i + 1
        while j < len(spans):
            state, a, b = spans[j]
            if state in moving:
                chain.append(j)
                j += 1
                continue
            bridgeable = (
                state in (State.STOP, State.UNKNOWN)
                and j + 1 < len(spans)
                and spans[j + 1][0] in moving
            )
            too_long = (state == State.UNKNOWN and (b - a + 1) > config.unknown_split_s) or (
                state == State.STOP and (b - a + 1) > config.max_in_run_break_s
            )
            if not bridgeable or too_long:
                break
            j += 1
        next_i = max(j, i + 1)

        while chain and spans[chain[0]][0] == State.INVALID:
            chain.pop(0)
        while chain and (
            spans[chain[-1]][0] == State.INVALID
            or _run_tail_drop_m(frame, spans, chain[-1]) < config.tail_min_drop_m
        ):
            chain.pop()
        if chain:
            start, end = spans[chain[0]][1], spans[chain[-1]][2]
            if (end - start + 1) >= config.min_run_s and (
                frame.alt[start] - frame.alt[end]
            ) >= config.min_run_drop_m:
                runs.append((start, end))
        i = next_i
    return runs


def _lift_identity(anchored: Sequence[LiftSpan], a: int, b: int) -> tuple[str | None, str | None]:
    best: LiftSpan | None = None
    best_overlap = 0
    for span in anchored:
        overlap = min(b, span.end) - max(a, span.start) + 1
        if overlap > best_overlap:
            best, best_overlap = span, overlap
    return (best.lift_name, best.external_track_id) if best is not None else (None, None)


def _record(
    frame: FeatureFrame,
    a: int,
    b: int,
    kind: str,
    sequence_index: int,
    masked: Sequence[bool],
    config: AnalyzerConfig,
    lift_name: str | None,
    track_id: str | None,
) -> ActionRecord:
    span_seconds = list(range(a, b + 1))
    stat_seconds = [i for i in span_seconds if not masked[i]]
    bounds_seconds = stat_seconds or span_seconds

    top_point = None
    if stat_seconds:
        masked_count = (b - a + 1) - len(stat_seconds)
        distance = sum(
            haversine_m(frame.lat[i], frame.lon[i], frame.lat[i + 1], frame.lon[i + 1])
            for i in stat_seconds
            if i + 1 <= b and not masked[i + 1]
        )
        speeds = [frame.speed[i] for i in stat_seconds]
        duration_s = float(max(0, (b - a) - masked_count))
        avg_speed = sum(speeds) / len(speeds)
        min_speed = min(speeds)

        top_speed = 0.0
        allowed = set(stat_seconds)
        for p in frame.points:
            second = frame.index_at(p.recorded_at)
            if second not in allowed or p.speed_mps is None:
                continue
            reference = max(frame.speed[second], config.spike_floor_mps)
            if p.speed_mps <= reference * config.spike_ratio and p.speed_mps > top_speed:
                top_speed, top_point = float(p.speed_mps), p
        max_speed = top_speed
    else:
        # Every second is masked. Duration/distance/speed stats have nothing to
        # measure and must not fall back to the whole span (that would pair a
        # nonzero duration/avg speed with zero distance, which is incoherent).
        # Bounds (altitude, lat/long) still come from the whole span below so
        # they are never empty.
        distance = 0.0
        duration_s = 0.0
        avg_speed = 0.0
        min_speed = 0.0
        max_speed = 0.0

    altitudes = [frame.alt[i] for i in bounds_seconds]
    lats = [frame.lat[i] for i in bounds_seconds]
    lons = [frame.lon[i] for i in bounds_seconds]

    return ActionRecord(
        action_type=kind,
        sequence_index=sequence_index,
        started_at=frame.time_at(a),
        ended_at=frame.time_at(b),
        duration_s=duration_s,
        distance_m=distance,
        avg_speed_mps=avg_speed,
        max_speed_mps=max_speed,
        min_speed_mps=min_speed,
        vertical_m=max(altitudes) - min(altitudes),
        min_altitude_m=min(altitudes),
        max_altitude_m=max(altitudes),
        min_lat=min(lats),
        max_lat=max(lats),
        min_long=min(lons),
        max_long=max(lons),
        top_speed_lat=top_point.latitude if top_point is not None else None,
        top_speed_long=top_point.longitude if top_point is not None else None,
        top_speed_alt_m=top_point.altitude_m if top_point is not None else None,
        time_of_day=None,
        external_track_id=track_id,
        source=LIVE_SOURCE,
        lift_name=lift_name,
    )


def _bbox_center(actions: Iterable[ActionRecord]) -> tuple[float | None, float | None]:
    lats: list[float] = []
    longs: list[float] = []
    for action in actions:
        lats.extend(v for v in (action.min_lat, action.max_lat) if v is not None)
        longs.extend(v for v in (action.min_long, action.max_long) if v is not None)
    if not lats or not longs:
        return None, None
    return (min(lats) + max(lats)) / 2.0, (min(longs) + max(longs)) / 2.0
