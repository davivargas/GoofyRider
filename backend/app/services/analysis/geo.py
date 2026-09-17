"""Small planar and spherical geometry helpers. Pure functions."""

from __future__ import annotations

from collections.abc import Sequence
import math

EARTH_RADIUS_M = 6_371_000.0
_M_PER_DEG_LAT = 110_540.0
_M_PER_DEG_LON_EQUATOR = 111_320.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def to_local_xy(lat: float, lon: float, lat0: float, lon0: float) -> tuple[float, float]:
    """Equirectangular projection in metres around (lat0, lon0). x is east, y is north."""
    x = (lon - lon0) * _M_PER_DEG_LON_EQUATOR * math.cos(math.radians(lat0))
    y = (lat - lat0) * _M_PER_DEG_LAT
    return x, y


def segment_distance_bearing(
    px: float, py: float, ax: float, ay: float, bx: float, by: float
) -> tuple[float, float]:
    """Distance from P to segment AB in metres, and the bearing of AB in degrees."""
    dx = bx - ax
    dy = by - ay
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0.0 else ((px - ax) * dx + (py - ay) * dy) / length_sq
    t = max(0.0, min(1.0, t))
    cx = ax + t * dx
    cy = ay + t * dy
    return math.hypot(px - cx, py - cy), math.degrees(math.atan2(dx, dy)) % 360.0


def bearing_gap_deg(a: float, b: float) -> float:
    """Smallest angle between two bearings, ignoring direction of travel (0 to 90)."""
    diff = abs((a - b + 180.0) % 360.0 - 180.0)
    return min(diff, 180.0 - diff)


def circular_variance(bearings_deg: Sequence[float]) -> float:
    """0 for identical bearings, 1 for bearings spread evenly around the circle."""
    if not bearings_deg:
        return 1.0
    sin_sum = sum(math.sin(math.radians(b)) for b in bearings_deg)
    cos_sum = sum(math.cos(math.radians(b)) for b in bearings_deg)
    return 1.0 - math.hypot(sin_sum, cos_sum) / len(bearings_deg)
