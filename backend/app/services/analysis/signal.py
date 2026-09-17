"""Quality gates, 1 Hz resampling, altitude fusion, and the per-second feature frame."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from datetime import timedelta
import math

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.geo import circular_variance
from app.services.analysis.geo import haversine_m
from app.services.analysis.types import RawPoint

_SEA_LEVEL_HPA = 1013.25
_MIN_VERTICAL_ACCURACY_M = 3.0
_BARO_WARMUP_S = 30.0
_LEGACY_SPEED_WINDOW = 5


@dataclass(frozen=True)
class FeatureFrame:
    """One row per second from `start`. All lists have the same length."""

    start: datetime
    lat: list[float]
    lon: list[float]
    alt: list[float]
    speed: list[float]
    vrate: list[float]
    heading_var: list[float]
    hacc: list[float]
    gap: list[bool]
    point_index: list[int]
    points: list[RawPoint]
    used_barometer: bool

    def __len__(self) -> int:
        return len(self.lat)

    def time_at(self, index: int) -> datetime:
        return self.start + timedelta(seconds=index)

    def index_at(self, when: datetime) -> int:
        raw = round((when - self.start).total_seconds())
        return max(0, min(len(self) - 1, raw))


def condition(points: Sequence[RawPoint], config: AnalyzerConfig) -> FeatureFrame | None:
    kept = _apply_gates(points, config)
    if len(kept) < 2:
        return None
    point_speeds = _point_speeds(kept, config)
    point_alts, used_barometer = _point_altitudes(kept, config)

    start = kept[0].recorded_at.replace(microsecond=0)
    offsets = [(p.recorded_at - start).total_seconds() for p in kept]
    n = int(offsets[-1]) + 1
    if n < 2:
        return None
    lat = [kept[0].latitude] * n
    lon = [kept[0].longitude] * n
    alt = [point_alts[0]] * n
    speed = [0.0] * n
    hacc = [kept[0].accuracy_m or 0.0] * n
    gap = [False] * n
    point_index = [0] * n

    for k in range(len(kept) - 1):
        a, b = kept[k], kept[k + 1]
        ia, ib = int(offsets[k]), int(offsets[k + 1])
        dt = offsets[k + 1] - offsets[k]
        implied = haversine_m(a.latitude, a.longitude, b.latitude, b.longitude) / dt
        dense = dt <= 3.5
        for i in range(ia, min(ib, n - 1) + 1):
            f = (i - ia) / max(ib - ia, 1)
            alt[i] = point_alts[k] + f * (point_alts[k + 1] - point_alts[k])
            hacc[i] = (a.accuracy_m if f < 0.5 else b.accuracy_m) or 0.0
            point_index[i] = k if f < 0.5 else k + 1
            if implied < config.still_mps:
                lat[i], lon[i] = a.latitude, a.longitude
                speed[i] = (
                    point_speeds[k] + f * (point_speeds[k + 1] - point_speeds[k]) if dense else 0.0
                )
                continue
            lat[i] = a.latitude + f * (b.latitude - a.latitude)
            lon[i] = a.longitude + f * (b.longitude - a.longitude)
            if dense:
                speed[i] = point_speeds[k] + f * (point_speeds[k + 1] - point_speeds[k])
            else:
                speed[i] = implied
                gap[i] = dt > config.bridge_max_s
    lat[-1], lon[-1] = kept[-1].latitude, kept[-1].longitude
    alt[-1], speed[-1] = point_alts[-1], point_speeds[-1]
    point_index[-1] = len(kept) - 1

    alt_window = config.baro_alt_window_s if used_barometer else config.gps_alt_window_s
    smooth_alt = centered_mean(alt, alt_window)
    smooth_speed = centered_mean(speed, config.speed_window_s)
    return FeatureFrame(
        start=start,
        lat=lat,
        lon=lon,
        alt=smooth_alt,
        speed=smooth_speed,
        vrate=_vertical_rate(smooth_alt, config.vrate_half_window_s),
        heading_var=_heading_variance(lat, lon, config.heading_window_s),
        hacc=hacc,
        gap=gap,
        point_index=point_index,
        points=kept,
        used_barometer=used_barometer,
    )


def centered_mean(values: Sequence[float], window: int) -> list[float]:
    """Centered rolling mean whose window shrinks at the edges."""
    half = window // 2
    n = len(values)
    prefix = [0.0]
    for value in values:
        prefix.append(prefix[-1] + value)
    out: list[float] = []
    for i in range(n):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        out.append((prefix[hi] - prefix[lo]) / (hi - lo))
    return out


def smooth_speeds_centered_mean(speeds: Sequence[float]) -> list[float]:
    """Legacy reference smoother: window 5 with edge padding by boundary repeat."""
    if not speeds:
        return []
    half = _LEGACY_SPEED_WINDOW // 2
    n = len(speeds)
    out: list[float] = []
    for i in range(n):
        total = 0.0
        for k in range(-half, half + 1):
            total += float(speeds[max(0, min(n - 1, i + k))])
        out.append(total / _LEGACY_SPEED_WINDOW)
    return out


def _apply_gates(points: Sequence[RawPoint], config: AnalyzerConfig) -> list[RawPoint]:
    kept: list[RawPoint] = []
    for p in points:
        if p.accuracy_m is not None and p.accuracy_m > config.accuracy_reject_m:
            continue
        if kept:
            last = kept[-1]
            dt = (p.recorded_at - last.recorded_at).total_seconds()
            if dt <= 0:
                continue
            implied = haversine_m(last.latitude, last.longitude, p.latitude, p.longitude) / dt
            if implied > config.jump_reject_mps:
                continue
        kept.append(p)
    return kept


def _point_speeds(kept: Sequence[RawPoint], config: AnalyzerConfig) -> list[float]:
    speeds: list[float] = []
    for k, p in enumerate(kept):
        trusted = p.speed_mps is not None and (
            p.speed_accuracy_mps is None or p.speed_accuracy_mps < config.speed_accuracy_trust_mps
        )
        if trusted and p.speed_mps is not None:
            speeds.append(float(p.speed_mps))
            continue
        neighbour = kept[k - 1] if k > 0 else kept[k + 1]
        dt = abs((p.recorded_at - neighbour.recorded_at).total_seconds())
        distance = haversine_m(p.latitude, p.longitude, neighbour.latitude, neighbour.longitude)
        speeds.append(distance / dt if dt > 0 else 0.0)
    return speeds


def _point_altitudes(kept: Sequence[RawPoint], config: AnalyzerConfig) -> tuple[list[float], bool]:
    gps = [p.altitude_m for p in kept]
    first_known = next((a for a in gps if a is not None), None)
    if first_known is None:
        return [0.0] * len(kept), False
    if not all(p.pressure_hpa is not None for p in kept):
        filled: list[float] = []
        last = float(first_known)
        for a in gps:
            last = float(a) if a is not None else last
            filled.append(last)
        return filled, False

    barometric = [
        44_330.0 * (1.0 - (float(p.pressure_hpa or _SEA_LEVEL_HPA) / _SEA_LEVEL_HPA) ** 0.1903)
        for p in kept
    ]
    # Start from the mean GPS-minus-barometer difference of the first 30 s, so one noisy
    # first fix cannot bias the whole session. (The accuracy gate has already removed
    # outliers, and a median is degenerate for noise that alternates around the truth.)
    warmup = [
        float(a) - b
        for p, a, b in zip(kept, gps, barometric, strict=True)
        if a is not None and (p.recorded_at - kept[0].recorded_at).total_seconds() <= _BARO_WARMUP_S
    ]
    offset = sum(warmup) / len(warmup) if warmup else float(first_known) - barometric[0]
    fused: list[float] = []
    previous_time = kept[0].recorded_at
    for p, a, b in zip(kept, gps, barometric, strict=True):
        if a is not None:
            dt = (p.recorded_at - previous_time).total_seconds()
            trust = _MIN_VERTICAL_ACCURACY_M / max(
                p.vertical_accuracy_m or _MIN_VERTICAL_ACCURACY_M, _MIN_VERTICAL_ACCURACY_M
            )
            weight = min(1.0, dt / config.baro_offset_tau_s) * trust
            offset += weight * ((float(a) - b) - offset)
        previous_time = p.recorded_at
        fused.append(b + offset)
    return fused, True


def _vertical_rate(alt: Sequence[float], half_window: int) -> list[float]:
    n = len(alt)
    out: list[float] = []
    for i in range(n):
        lo, hi = max(0, i - half_window), min(n - 1, i + half_window)
        out.append((alt[hi] - alt[lo]) / (hi - lo) if hi > lo else 0.0)
    return out


def _heading_variance(lat: Sequence[float], lon: Sequence[float], window: int) -> list[float]:
    n = len(lat)
    bearings: list[float | None] = [None] * n
    for i in range(1, n - 1):
        north = (lat[i + 1] - lat[i - 1]) * 110_540.0
        east = (lon[i + 1] - lon[i - 1]) * 111_320.0 * math.cos(math.radians(lat[i]))
        if math.hypot(north, east) > 1.0:
            bearings[i] = math.degrees(math.atan2(east, north)) % 360.0
    half = window // 2
    out: list[float] = []
    for i in range(n):
        known = [b for b in bearings[max(0, i - half) : i + half + 1] if b is not None]
        out.append(circular_variance(known) if len(known) >= 3 else 1.0)
    return out
