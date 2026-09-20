"""Map SkiAPI raw or legacy payloads to SourceResortView (spec 5.2, Phase 2 reuse)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from app.services.catalog_types import SOURCE_SKI_API
from app.services.catalog_types import SourceResortView
from app.services.ski_api_resort_source import COUNTRY_NAME_BY_CODE
from app.services.ski_api_resort_source import map_ski_api_resort

COUNTRY_CODE_BY_NAME = {name: code for code, name in COUNTRY_NAME_BY_CODE.items()}


def _text(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _float(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)


def _int(value: object) -> int | None:
    number = _float(value)
    return None if number is None else round(number)


def map_ski_api_view(payload: Mapping[str, Any]) -> SourceResortView:
    if payload.get("legacy") is True:
        country = _text(payload.get("country"))
        return SourceResortView(
            source=SOURCE_SKI_API,
            name=_text(payload.get("name")),
            latitude=_float(payload.get("latitude")),
            longitude=_float(payload.get("longitude")),
            boundary=None,
            bbox=None,
            country=country,
            country_code=COUNTRY_CODE_BY_NAME.get(country or ""),
            region=_text(payload.get("region")),
            region_code=None,
            city=_text(payload.get("city")),
            elevation_base_m=_int(payload.get("elevation_base_m")),
            elevation_top_m=_int(payload.get("elevation_top_m")),
            lift_envelope=None,
            status=None,
            activities=(),
        )

    record = map_ski_api_resort(dict(payload))
    raw_country = _text(payload.get("country"))
    country_code = raw_country.upper() if raw_country and len(raw_country) == 2 else None

    elevation_base_m, elevation_top_m = record.elevation_base_m, record.elevation_top_m
    city = record.city
    detail = payload.get("detail")
    if isinstance(detail, Mapping):
        detail_elevation = detail.get("elevation")
        if isinstance(detail_elevation, Mapping):
            elevation_base_m = _int(detail_elevation.get("base_m"))
            elevation_top_m = _int(detail_elevation.get("top_m"))
        detail_city = _text(detail.get("city"))
        if detail_city is not None:
            city = detail_city

    return SourceResortView(
        source=SOURCE_SKI_API,
        name=record.name,
        latitude=record.latitude,
        longitude=record.longitude,
        boundary=None,
        bbox=None,
        country=record.country,
        country_code=country_code or COUNTRY_CODE_BY_NAME.get(record.country),
        region=record.region,
        region_code=None,
        city=city,
        elevation_base_m=elevation_base_m,
        elevation_top_m=elevation_top_m,
        lift_envelope=None,
        status=None,
        activities=(),
    )
