"""Anchor stretches of the track to catalog lift lines (spec section 6)."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from itertools import pairwise
import math

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import bearing_gap_deg
from app.services.analysis.geo import segment_distance_bearing
from app.services.analysis.geo import to_local_xy
from app.services.analysis.signal import FeatureFrame
from app.services.analysis.types import ResortLift

_DOWNLOAD_AERIALWAYS = frozenset({"gondola", "cable_car", "mixed_lift"})
_LOW_GAIN_LIFT_TYPES = frozenset({"surface", "tbar", "magic_carpet"})
_BBOX_MARGIN_M = 200.0


@dataclass(frozen=True)
class LiftSpan:
    start: int
    end: int
    lift_name: str | None
    external_track_id: str | None


def resort_area(
    lifts: Sequence[ResortLift], config: AnalyzerConfig
) -> tuple[float, float, float, float] | None:
    vertices = [v for lift in lifts for v in lift.polyline]
    if not vertices:
        return None
    lats = [float(v[0]) for v in vertices]
    lons = [float(v[1]) for v in vertices]
    pad_lat = config.area_pad_m / 110_540.0
    pad_lon = config.area_pad_m / (111_320.0 * math.cos(math.radians(lats[0])))
    return min(lats) - pad_lat, max(lats) + pad_lat, min(lons) - pad_lon, max(lons) + pad_lon


def anchor(
    frame: FeatureFrame, lifts: Sequence[ResortLift], config: AnalyzerConfig
) -> list[LiftSpan]:
    usable = [lift for lift in lifts if len(lift.polyline) >= 2]
    n = len(frame)
    if not usable or n == 0:
        return []
    lat0, lon0 = frame.lat[0], frame.lon[0]
    xy = [to_local_xy(frame.lat[i], frame.lon[i], lat0, lon0) for i in range(n)]
    bearings = _track_bearings(xy, config)

    candidates: list[tuple[int, int, ResortLift]] = []
    for lift in usable:
        line = [to_local_xy(float(v[0]), float(v[1]), lat0, lon0) for v in lift.polyline]
        near, riding = _classify_seconds(frame, xy, bearings, line, config)
        candidates.extend(
            (a, b, lift) for a, b in _spans_for_lift(frame, xy, near, riding, line, lift, config)
        )

    candidates.sort(key=lambda c: (c[0], c[1]))
    chosen: list[tuple[int, int, ResortLift]] = []
    for cand in candidates:
        if chosen and cand[0] <= chosen[-1][1]:
            if cand[1] - cand[0] > chosen[-1][1] - chosen[-1][0]:
                chosen[-1] = cand
            continue
        chosen.append(cand)
    return [LiftSpan(a, b, lift.name, lift.external_track_id) for a, b, lift in chosen]


def _track_bearings(
    xy: Sequence[tuple[float, float]], config: AnalyzerConfig
) -> list[float | None]:
    n = len(xy)
    half = config.lift_bearing_half_window_s
    out: list[float | None] = [None] * n
    for i in range(n):
        ax, ay = xy[max(0, i - half)]
        bx, by = xy[min(n - 1, i + half)]
        if math.hypot(bx - ax, by - ay) > config.lift_bearing_min_move_m:
            out[i] = math.degrees(math.atan2(bx - ax, by - ay)) % 360.0
    return out


def _classify_seconds(
    frame: FeatureFrame,
    xy: Sequence[tuple[float, float]],
    bearings: Sequence[float | None],
    line: Sequence[tuple[float, float]],
    config: AnalyzerConfig,
) -> tuple[list[bool], list[bool]]:
    n = len(xy)
    near = [False] * n
    riding = [False] * n
    min_x = min(p[0] for p in line) - _BBOX_MARGIN_M
    max_x = max(p[0] for p in line) + _BBOX_MARGIN_M
    min_y = min(p[1] for p in line) - _BBOX_MARGIN_M
    max_y = max(p[1] for p in line) + _BBOX_MARGIN_M
    (ex, ey), (fx, fy) = line[0], line[-1]
    axis_x, axis_y = fx - ex, fy - ey
    axis_len = math.hypot(axis_x, axis_y) or 1.0
    for i, (px, py) in enumerate(xy):
        if not (min_x <= px <= max_x and min_y <= py <= max_y):
            continue
        best_distance, best_bearing = math.inf, 0.0
        for (ax, ay), (bx, by) in pairwise(line):
            distance, bearing = segment_distance_bearing(px, py, ax, ay, bx, by)
            if distance < best_distance:
                best_distance, best_bearing = distance, bearing
        if best_distance <= config.lift_radius_m * config.lift_near_factor:
            near[i] = True
        along = ((px - ex) * axis_x + (py - ey) * axis_y) / axis_len
        track_bearing = bearings[i]
        if (
            best_distance <= config.lift_radius_m
            and 0.0 <= along <= axis_len
            and track_bearing is not None
            and frame.speed[i] >= config.lift_riding_min_mps
            and bearing_gap_deg(track_bearing, best_bearing) <= config.lift_bearing_deg
        ):
            riding[i] = True
    return near, riding


def _spans_for_lift(
    frame: FeatureFrame,
    xy: Sequence[tuple[float, float]],
    near: Sequence[bool],
    riding: Sequence[bool],
    line: Sequence[tuple[float, float]],
    lift: ResortLift,
    config: AnalyzerConfig,
) -> list[tuple[int, int]]:
    indices = [i for i, flag in enumerate(riding) if flag]
    length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in pairwise(line))
    low_gain = lift.lift_type in _LOW_GAIN_LIFT_TYPES
    can_download = lift.osm_aerialway in _DOWNLOAD_AERIALWAYS
    spans: list[tuple[int, int]] = []
    k = 0
    while k < len(indices):
        start = end = indices[k]
        m = k
        while m + 1 < len(indices):
            nxt = indices[m + 1]
            if nxt - end > config.lift_gap_s or not all(near[q] for q in range(end, nxt + 1)):
                break
            end = nxt
            m += 1
        duration = end - start + 1
        riding_count = m - k + 1
        moved = math.hypot(xy[end][0] - xy[start][0], xy[end][1] - xy[start][1])
        change = frame.alt[end] - frame.alt[start]
        speeds = sorted(frame.speed[q] for q in indices[k : m + 1])
        median = speeds[len(speeds) // 2]
        if low_gain:
            direction_ok = (
                change >= config.low_gain_min_change_m and median <= config.low_gain_max_median_mps
            )
        else:
            direction_ok = change >= config.lift_min_gain_m or (
                can_download and change <= -config.lift_min_gain_m
            )
        if (
            duration >= config.lift_min_duration_s
            and riding_count >= config.lift_riding_fraction * duration
            and moved >= min(config.lift_min_move_m, 0.5 * length)
            and median <= config.lift_max_median_mps
            and direction_ok
        ):
            spans.append((start, end))
        k = m + 1
    return spans
