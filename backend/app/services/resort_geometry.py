"""Pure GeoJSON helpers for catalog matching and plausibility checks (spec 5.2, 5.4, 6)."""

from __future__ import annotations

from collections.abc import Mapping
from collections.abc import Sequence
from typing import Any

from app.services.analysis.geo import haversine_m
from app.services.catalog_types import BBox

__all__ = [
    "bbox_of_geometry",
    "centroid_of_geometry",
    "haversine_m",
    "point_in_bbox",
    "point_in_geometry",
]

Ring = Sequence[Sequence[float]]


def _polygons(geometry: Mapping[str, Any] | None) -> list[list[Ring]]:
    if not isinstance(geometry, Mapping):
        return []
    kind = geometry.get("type")
    coords = geometry.get("coordinates")
    if kind == "Polygon" and isinstance(coords, list):
        return [coords]
    if kind == "MultiPolygon" and isinstance(coords, list):
        return [polygon for polygon in coords if isinstance(polygon, list)]
    return []


def bbox_of_geometry(geometry: Mapping[str, Any] | None) -> BBox | None:
    lats: list[float] = []
    lons: list[float] = []
    for polygon in _polygons(geometry):
        for ring in polygon:
            for position in ring:
                lons.append(float(position[0]))
                lats.append(float(position[1]))
    if not lats:
        return None
    return (min(lats), min(lons), max(lats), max(lons))


def _ring_area_and_centroid(ring: Ring) -> tuple[float, float, float]:
    """Shoelace on (lon, lat); returns (|area|, centroid_lat, centroid_lon)."""
    n = len(ring)
    if n < 3:
        return 0.0, 0.0, 0.0
    area2 = 0.0
    cx = 0.0
    cy = 0.0
    for i in range(n):
        x0, y0 = float(ring[i][0]), float(ring[i][1])
        x1, y1 = float(ring[(i + 1) % n][0]), float(ring[(i + 1) % n][1])
        cross = x0 * y1 - x1 * y0
        area2 += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(area2) < 1e-15:
        lons = [float(p[0]) for p in ring]
        lats = [float(p[1]) for p in ring]
        return 0.0, sum(lats) / n, sum(lons) / n
    return abs(area2) / 2.0, cy / (3.0 * area2), cx / (3.0 * area2)


def centroid_of_geometry(geometry: Mapping[str, Any] | None) -> tuple[float, float] | None:
    best: tuple[float, float, float] | None = None
    for polygon in _polygons(geometry):
        if not polygon:
            continue
        candidate = _ring_area_and_centroid(polygon[0])
        if best is None or candidate[0] > best[0]:
            best = candidate
    if best is None:
        return None
    return best[1], best[2]


def _point_in_ring(lat: float, lon: float, ring: Ring) -> bool:
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = float(ring[i][0]), float(ring[i][1])
        xj, yj = float(ring[j][0]), float(ring[j][1])
        crosses = (yi > lat) != (yj > lat)
        if crosses:
            x_at_lat = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < x_at_lat:
                inside = not inside
        j = i
    return inside


def point_in_geometry(lat: float, lon: float, geometry: Mapping[str, Any] | None) -> bool:
    for polygon in _polygons(geometry):
        if not polygon or not _point_in_ring(lat, lon, polygon[0]):
            continue
        if any(_point_in_ring(lat, lon, hole) for hole in polygon[1:]):
            continue
        return True
    return False


def point_in_bbox(lat: float, lon: float, bbox: BBox) -> bool:
    min_lat, min_lon, max_lat, max_lon = bbox
    return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon
