"""Map legacy `ski_api` source records to SourceResortView (spec 5.2).

The SkiAPI enrichment path was removed on 2026-09-20 (deprecated provider). The
only `ski_api` source records that remain are the legacy rows written by Alembic
revision `0016_resort_catalog_sources` for resorts that carried
`external_source='ski_api'` before the multi-source catalog landed. They stay
`linked` with `match_method='legacy'` and still participate in the merge, so
their payload shape still needs a mapper.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from app.services.catalog_types import SOURCE_SKI_API
from app.services.catalog_types import SourceResortView
from app.services.exceptions import ValidationError

COUNTRY_NAME_BY_CODE = {
    "AD": "Andorra",
    "AR": "Argentina",
    "AT": "Austria",
    "AU": "Australia",
    "CA": "Canada",
    "CH": "Switzerland",
    "CL": "Chile",
    "DE": "Germany",
    "ES": "Spain",
    "FI": "Finland",
    "FR": "France",
    "IT": "Italy",
    "JP": "Japan",
    "NO": "Norway",
    "NZ": "New Zealand",
    "SE": "Sweden",
    "US": "United States",
}

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


def map_legacy_resort_view(payload: Mapping[str, Any]) -> SourceResortView:
    if payload.get("legacy") is not True:
        raise ValidationError("Unsupported ski_api payload; only legacy records remain.")

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
