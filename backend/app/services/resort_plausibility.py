"""Field plausibility checks used by the merge (spec 6.1, 6.3). Pure functions."""

from __future__ import annotations

from collections.abc import Mapping
import re
from typing import Any

from app.services.resort_geometry import point_in_geometry

ELEVATION_MIN_M = 0
ELEVATION_MAX_M = 6000
ENVELOPE_TOLERANCE_M = 150
NAME_MAX_LENGTH = 120
_COUNTRY_CODE = re.compile(r"^[A-Z]{2}$")


def check_text(value: str | None) -> bool:
    return isinstance(value, str) and bool(value.strip())


def check_name(value: str | None) -> bool:
    if value is None or not check_text(value):
        return False
    return len(value.strip()) <= NAME_MAX_LENGTH


def check_country_code(value: str | None) -> bool:
    return isinstance(value, str) and _COUNTRY_CODE.match(value) is not None


def check_coordinates(
    latitude: float | None, longitude: float | None, boundary: Mapping[str, Any] | None
) -> bool:
    if latitude is None or longitude is None:
        return False
    if not (-90.0 <= latitude <= 90.0 and -180.0 <= longitude <= 180.0):
        return False
    if boundary is None:
        return True
    return point_in_geometry(latitude, longitude, boundary)


def check_elevations(
    base_m: int | None, top_m: int | None, envelope: tuple[int, int] | None
) -> bool:
    if base_m is None or top_m is None:
        return False
    if not (
        ELEVATION_MIN_M <= base_m <= ELEVATION_MAX_M and ELEVATION_MIN_M <= top_m <= ELEVATION_MAX_M
    ):
        return False
    if top_m <= base_m:
        return False
    if envelope is None:
        return True
    env_min, env_max = envelope
    return base_m >= env_min - ENVELOPE_TOLERANCE_M and top_m <= env_max + ENVELOPE_TOLERANCE_M
