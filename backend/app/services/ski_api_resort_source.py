from dataclasses import dataclass
import re
from collections.abc import Mapping
from typing import Any
from typing import Protocol
from typing import cast

import httpx

from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError

SKI_API_EXTERNAL_SOURCE = "ski_api"
DEFAULT_REGION = "Unknown"
ELEVATION_RANGE_PATTERN = re.compile(r"(\d+)\s*m\s*[^0-9]+\s*(\d+)\s*m")

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

US_REGION_NAME_BY_CODE = {
    "AK": "Alaska",
    "AZ": "Arizona",
    "CA": "California",
    "CO": "Colorado",
    "CT": "Connecticut",
    "ID": "Idaho",
    "MA": "Massachusetts",
    "ME": "Maine",
    "MI": "Michigan",
    "MT": "Montana",
    "NC": "North Carolina",
    "NH": "New Hampshire",
    "NM": "New Mexico",
    "NV": "Nevada",
    "NY": "New York",
    "OH": "Ohio",
    "OR": "Oregon",
    "PA": "Pennsylvania",
    "SD": "South Dakota",
    "UT": "Utah",
    "VA": "Virginia",
    "VT": "Vermont",
    "WA": "Washington",
    "WI": "Wisconsin",
    "WV": "West Virginia",
    "WY": "Wyoming",
}

CANADA_REGION_NAME_BY_CODE = {
    "AB": "Alberta",
    "BC": "British Columbia",
    "MB": "Manitoba",
    "NB": "New Brunswick",
    "NL": "Newfoundland and Labrador",
    "NS": "Nova Scotia",
    "NT": "Northwest Territories",
    "NU": "Nunavut",
    "ON": "Ontario",
    "PE": "Prince Edward Island",
    "QC": "Quebec",
    "SK": "Saskatchewan",
    "YT": "Yukon",
}


@dataclass(frozen=True)
class ExternalResortRecord:
    external_source: str
    external_id: str
    name: str
    country: str
    region: str
    city: str | None
    latitude: float | None
    longitude: float | None
    elevation_base_m: int | None
    elevation_top_m: int | None


class ExternalResortSourceProtocol(Protocol):
    def fetch_resorts(self) -> list[ExternalResortRecord]:
        ...


class SkiApiPageFetcherProtocol(Protocol):
    def __call__(self, page: int, page_size: int) -> object:
        ...


class SkiApiResortSource:
    def __init__(
        self,
        base_url: str,
        api_key: str | None,
        api_host: str | None,
        page_size: int,
        timeout_seconds: int,
        page_fetcher: SkiApiPageFetcherProtocol | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._api_host = api_host
        self._page_size = page_size
        self._timeout_seconds = timeout_seconds
        self._page_fetcher = page_fetcher

    def fetch_resorts(self) -> list[ExternalResortRecord]:
        resorts: list[ExternalResortRecord] = []
        next_page = 1

        while next_page is not None:
            payload = self._fetch_page(page=next_page)
            resorts.extend(map_ski_api_resorts_page(payload))
            next_page = _parse_next_page(payload.get("next_page"))

        return resorts

    def _fetch_page(self, page: int) -> dict[str, Any]:
        if self._page_fetcher is not None:
            payload = self._page_fetcher(page, self._page_size)
            return _require_object_payload(payload)

        headers = _build_ski_api_headers(
            api_key=self._api_key,
            api_host=self._api_host,
        )

        try:
            with httpx.Client(timeout=float(self._timeout_seconds)) as client:
                response = client.get(
                    f"{self._base_url}/resort",
                    params={"page": page, "per_page": self._page_size},
                    headers=headers,
                )
                response.raise_for_status()
                payload = response.json()
        except httpx.HTTPError as exc:
            raise ServiceUnavailableError("Ski API provider unavailable.") from exc
        except ValueError as exc:
            raise ValidationError("Ski API returned invalid JSON.") from exc

        return _require_object_payload(payload)


def map_ski_api_resorts_page(payload: dict[str, Any]) -> list[ExternalResortRecord]:
    raw_records = payload.get("data")
    if not isinstance(raw_records, list):
        raise ValidationError("Ski API resorts payload must include a data list.")
    raw_record_items = cast(list[object], raw_records)

    mapped_records: list[ExternalResortRecord] = []
    for raw_record_obj in raw_record_items:
        raw_record = _require_object_payload(
            raw_record_obj,
            error_message="Ski API resort entries must be objects.",
        )
        mapped_records.append(map_ski_api_resort(raw_record))

    return mapped_records


def map_ski_api_resort(payload: dict[str, Any]) -> ExternalResortRecord:
    external_id = _require_text(payload.get("slug"), field_name="slug")
    name = _require_text(payload.get("name"), field_name="name")
    country = _normalize_country(_require_text(payload.get("country"), field_name="country"))
    region = _normalize_region(
        country=country,
        region_value=_optional_text(payload.get("region")) or DEFAULT_REGION,
    )
    location = payload.get("location")
    latitude, longitude = _parse_location(location)
    elevation_base_m, elevation_top_m = _parse_elevation_range(payload.get("elevation"))

    return ExternalResortRecord(
        external_source=SKI_API_EXTERNAL_SOURCE,
        external_id=external_id,
        name=name,
        country=country,
        region=region,
        city=_optional_text(payload.get("city")),
        latitude=latitude,
        longitude=longitude,
        elevation_base_m=elevation_base_m,
        elevation_top_m=elevation_top_m,
    )


def _build_ski_api_headers(
    api_key: str | None,
    api_host: str | None,
) -> dict[str, str]:
    headers: dict[str, str] = {}
    if api_key:
        headers["X-RapidAPI-Key"] = api_key
    if api_host:
        headers["X-RapidAPI-Host"] = api_host
    return headers


def _parse_next_page(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str) and value.strip():
        try:
            parsed = int(value.strip())
        except ValueError as exc:
            raise ValidationError("Ski API next_page must be an integer or null.") from exc
        return parsed if parsed > 0 else None
    raise ValidationError("Ski API next_page must be an integer or null.")


def _parse_location(value: Any) -> tuple[float | None, float | None]:
    location = _optional_object_payload(value)
    if location is None:
        return None, None

    return (
        _optional_float(location.get("latitude")),
        _optional_float(location.get("longitude")),
    )


def _parse_elevation_range(value: Any) -> tuple[int | None, int | None]:
    elevation = _optional_object_payload(value)
    if elevation is not None:
        return (
            _optional_int(elevation.get("base_m")),
            _optional_int(elevation.get("top_m")),
        )

    text = _optional_text(value)
    if text is None:
        return None, None

    match = ELEVATION_RANGE_PATTERN.search(text)
    if match is None:
        return None, None

    return int(match.group(1)), int(match.group(2))


def _normalize_country(country_code_or_name: str) -> str:
    normalized = country_code_or_name.strip().upper()
    return COUNTRY_NAME_BY_CODE.get(normalized, country_code_or_name.strip())


def _normalize_region(country: str, region_value: str) -> str:
    normalized_region = region_value.strip()
    region_code = normalized_region.upper()

    if country == "Canada":
        return CANADA_REGION_NAME_BY_CODE.get(region_code, normalized_region)
    if country == "United States":
        return US_REGION_NAME_BY_CODE.get(region_code, normalized_region)
    return normalized_region


def _require_text(value: Any, field_name: str) -> str:
    text = _optional_text(value)
    if text is None:
        raise ValidationError(f"Ski API resort {field_name} is required.")
    return text


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValidationError("Ski API text fields must be strings.")

    normalized = value.strip()
    return normalized or None


def _optional_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError("Ski API numeric fields must be valid numbers.") from exc


def _optional_int(value: Any) -> int | None:
    parsed = _optional_float(value)
    if parsed is None:
        return None
    return int(round(parsed))


def _require_object_payload(
    value: object,
    *,
    error_message: str = "Ski API resorts payload must be an object.",
) -> dict[str, Any]:
    payload = _optional_object_payload(value)
    if payload is None:
        raise ValidationError(error_message)
    return payload


def _optional_object_payload(value: object) -> dict[str, Any] | None:
    if not isinstance(value, Mapping):
        return None
    mapping_value = cast(Mapping[object, object], value)

    payload: dict[str, Any] = {}
    for key, item in mapping_value.items():
        if isinstance(key, str):
            payload[key] = item
    return payload
