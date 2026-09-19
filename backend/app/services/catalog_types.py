"""Shared value types for the multi-source resort catalog (spec sections 4 and 5)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
from typing import Any

SOURCE_OPENSKIDATA = "openskidata"
SOURCE_SKI_API = "ski_api"
LIFT_SOURCE_OPENSKIDATA = "openskidata"
LIFT_SOURCE_OVERPASS = "overpass"

BBox = tuple[float, float, float, float]
"""(min_lat, min_lon, max_lat, max_lon)."""


def content_hash(payload: Mapping[str, Any]) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ExternalSourceRecord:
    source: str
    external_id: str
    payload: dict[str, Any]
    content_hash: str
    snapshot_built_at: datetime | None


@dataclass(frozen=True)
class ExternalLiftRecord:
    external_id: str
    ski_area_ids: tuple[str, ...]
    name: str
    lift_type: str
    osm_aerialway: str
    status: str | None
    polyline: tuple[tuple[float, float], ...]
    base_altitude_m: float | None
    top_altitude_m: float | None
    external_track_id: str


@dataclass(frozen=True)
class SourceResortView:
    source: str
    name: str | None
    latitude: float | None
    longitude: float | None
    boundary: dict[str, Any] | None
    bbox: BBox | None
    country: str | None
    country_code: str | None
    region: str | None
    region_code: str | None
    city: str | None
    elevation_base_m: int | None
    elevation_top_m: int | None
    lift_envelope: tuple[int, int] | None
    status: str | None
    activities: tuple[str, ...]
