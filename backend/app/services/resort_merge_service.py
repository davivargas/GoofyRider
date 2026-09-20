"""Precedence merge from linked source records and overrides into resorts (spec 6)."""

from __future__ import annotations

from collections.abc import Callable
from collections.abc import Mapping
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
import logging
from typing import Any

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.protocols import ResortFieldOverrideRepositoryProtocol
from app.repositories.protocols import ResortLiftRepositoryProtocol
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import ResortSourceRecordRepositoryProtocol
from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import SOURCE_SKI_API
from app.services.catalog_types import BBox
from app.services.catalog_types import SourceResortView
from app.services.exceptions import ValidationError
from app.services.legacy_resort_mapping import map_legacy_resort_view
from app.services.openskidata_mapping import ACTIVE_STATUSES
from app.services.openskidata_mapping import map_ski_area
from app.services.resort_plausibility import NAME_MAX_LENGTH
from app.services.resort_plausibility import REGION_CODE_MAX_LENGTH
from app.services.resort_plausibility import TEXT_MAX_LENGTH
from app.services.resort_plausibility import check_coordinates
from app.services.resort_plausibility import check_country_code
from app.services.resort_plausibility import check_elevations
from app.services.resort_plausibility import check_name
from app.services.resort_plausibility import check_text
from app.services.resort_plausibility import clamp_text

logger = logging.getLogger(__name__)

PRECEDENCE: tuple[str, ...] = (SOURCE_OPENSKIDATA, SOURCE_SKI_API)
PROVENANCE_MANUAL = "manual"
PROVENANCE_RULE = "rule"
PROVENANCE_DERIVED_LIFTS = "derived_lifts"
PROVENANCE_UNVALIDATED = "unvalidated"
PROVENANCE_NONE = "none"

#: Mergeable text fields and the length of their `resorts` column.
TEXT_FIELD_LIMITS: dict[str, int] = {
    "name": NAME_MAX_LENGTH,
    "country": TEXT_MAX_LENGTH,
    "region": TEXT_MAX_LENGTH,
    "city": TEXT_MAX_LENGTH,
    "region_code": REGION_CODE_MAX_LENGTH,
}

_VIEW_MAPPERS: dict[str, Callable[[Mapping[str, Any]], SourceResortView]] = {
    SOURCE_OPENSKIDATA: map_ski_area,
    SOURCE_SKI_API: map_legacy_resort_view,
}


@dataclass(frozen=True)
class LinkedView:
    view: SourceResortView
    missing: bool


@dataclass(frozen=True)
class MergeResult:
    name: str
    country: str
    country_code: str | None
    region: str
    region_code: str | None
    city: str | None
    latitude: float | None
    longitude: float | None
    boundary: dict[str, Any] | None
    bbox: BBox | None
    elevation_base_m: int | None
    elevation_top_m: int | None
    is_active: bool
    name_aliases: tuple[str, ...]
    provenance: dict[str, str]


@dataclass(frozen=True)
class MergeSummary:
    merged_count: int
    changed_count: int
    deactivated_count: int


def view_for_record(record: ResortSourceRecord) -> SourceResortView:
    mapper = _VIEW_MAPPERS.get(record.source)
    if mapper is None:
        raise ValidationError(f"No view mapper for source {record.source!r}.")
    return mapper(record.payload)


def _ordered(views: Sequence[LinkedView]) -> list[SourceResortView]:
    rank = {source: index for index, source in enumerate(PRECEDENCE)}
    return [
        lv.view
        for lv in sorted(
            views, key=lambda lv: (rank.get(lv.view.source, len(rank)), lv.view.source)
        )
    ]


def _pick(
    ordered: Sequence[SourceResortView],
    getter: Callable[[SourceResortView], Any],
    check: Callable[[Any], bool],
) -> tuple[Any, str]:
    for view in ordered:
        value = getter(view)
        if check(value):
            return value, view.source
    return None, PROVENANCE_NONE


def _pick_required(
    ordered: Sequence[SourceResortView],
    getter: Callable[[SourceResortView], str | None],
    check: Callable[[str | None], bool],
    current: str,
) -> tuple[str, str]:
    value, provenance = _pick(ordered, getter, check)
    if value is not None:
        return str(value), provenance
    for view in reversed(ordered):
        candidate = getter(view)
        if check_text(candidate):
            return str(candidate).strip(), PROVENANCE_UNVALIDATED
    return current, PROVENANCE_NONE


def _override_float(field: str, value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValidationError(f"Invalid override {field!r} for resort: {value!r}")
    return float(value)


def _override_int(field: str, value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"Invalid override {field!r} for resort: {value!r}")
    return value


def compute_merge(
    *,
    current_name: str,
    current_country: str,
    current_region: str,
    views: Sequence[LinkedView],
    overrides: Mapping[str, Any],
    lift_envelope: tuple[int, int] | None,
) -> MergeResult:
    ordered = _ordered(views)
    provenance: dict[str, str] = {}
    values: dict[str, Any] = {}

    boundary_view = next(
        (v for v in ordered if v.source == SOURCE_OPENSKIDATA and v.boundary), None
    )
    boundary = boundary_view.boundary if boundary_view else None
    bbox = boundary_view.bbox if boundary_view else None
    provenance["boundary"] = SOURCE_OPENSKIDATA if boundary is not None else PROVENANCE_NONE

    values["name"], provenance["name"] = _pick_required(
        ordered, lambda v: v.name, check_name, current_name
    )
    values["country"], provenance["country"] = _pick_required(
        ordered, lambda v: v.country, check_text, current_country
    )
    values["region"], provenance["region"] = _pick_required(
        ordered, lambda v: v.region, check_text, current_region
    )
    values["country_code"], provenance["country_code"] = _pick(
        ordered, lambda v: v.country_code, check_country_code
    )
    values["region_code"], provenance["region_code"] = _pick(
        ordered, lambda v: v.region_code, check_text
    )
    values["city"], provenance["city"] = _pick(ordered, lambda v: v.city, check_text)
    # Third-party text is unbounded; the columns are not. Clamp before anything downstream
    # (including the `unvalidated` fallback, which bypasses the length check).
    for field, max_length in TEXT_FIELD_LIMITS.items():
        values[field] = clamp_text(values[field], max_length)

    latitude: float | None = None
    longitude: float | None = None
    provenance["latitude"] = provenance["longitude"] = PROVENANCE_NONE
    for view in ordered:
        if check_coordinates(view.latitude, view.longitude, boundary):
            latitude, longitude = view.latitude, view.longitude
            provenance["latitude"] = provenance["longitude"] = view.source
            break

    envelope = lift_envelope
    if envelope is None:
        envelope = next((v.lift_envelope for v in ordered if v.lift_envelope is not None), None)
    base_m: int | None = None
    top_m: int | None = None
    provenance["elevation_base_m"] = provenance["elevation_top_m"] = PROVENANCE_NONE
    for view in ordered:
        if check_elevations(view.elevation_base_m, view.elevation_top_m, envelope):
            base_m, top_m = view.elevation_base_m, view.elevation_top_m
            provenance["elevation_base_m"] = provenance["elevation_top_m"] = view.source
            break
    if base_m is None and envelope is not None and envelope[1] > envelope[0]:
        base_m, top_m = envelope
        provenance["elevation_base_m"] = provenance["elevation_top_m"] = PROVENANCE_DERIVED_LIFTS

    is_active = any(
        not lv.missing
        and (
            lv.view.source != SOURCE_OPENSKIDATA
            or lv.view.status is None
            or lv.view.status in ACTIVE_STATUSES
        )
        for lv in views
    )
    provenance["is_active"] = PROVENANCE_RULE if views else PROVENANCE_NONE

    for field, value in overrides.items():
        if field in ("latitude", "longitude"):
            coordinate = _override_float(field, value)
            if field == "latitude":
                latitude = coordinate
            else:
                longitude = coordinate
        elif field in ("elevation_base_m", "elevation_top_m"):
            elevation = _override_int(field, value)
            if field == "elevation_base_m":
                base_m = elevation
            else:
                top_m = elevation
        elif field == "is_active":
            if not isinstance(value, bool):
                raise ValidationError(f"Invalid override {field!r} for resort: {value!r}")
            is_active = value
        else:
            if not isinstance(value, str):
                raise ValidationError(f"Invalid override {field!r} for resort: {value!r}")
            values[field] = clamp_text(value, TEXT_FIELD_LIMITS.get(field, TEXT_MAX_LENGTH))
        provenance[field] = PROVENANCE_MANUAL

    display_name = str(values["name"])
    aliases = sorted({v.name.strip() for v in ordered if v.name and v.name.strip() != display_name})

    return MergeResult(
        name=display_name,
        country=str(values["country"]),
        country_code=values["country_code"],
        region=str(values["region"]),
        region_code=values["region_code"],
        city=values["city"],
        latitude=latitude,
        longitude=longitude,
        boundary=boundary,
        bbox=bbox,
        elevation_base_m=base_m,
        elevation_top_m=top_m,
        is_active=is_active,
        name_aliases=tuple(aliases),
        provenance=provenance,
    )


class ResortMergeService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        record_repository: ResortSourceRecordRepositoryProtocol,
        override_repository: ResortFieldOverrideRepositoryProtocol,
        lift_repository: ResortLiftRepositoryProtocol,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._resorts = resort_repository
        self._records = record_repository
        self._overrides = override_repository
        self._lifts = lift_repository
        self._clock = clock or (lambda: datetime.now(UTC))

    def merge_stale(self, *, force: bool = False) -> MergeSummary:
        resorts = (
            self._resorts.list_all_for_matching() if force else self._resorts.list_stale_for_merge()
        )
        merged = changed = deactivated = 0
        for resort in resorts:
            was_active = resort.is_active
            if self.merge_resort(resort):
                changed += 1
            if was_active and not resort.is_active:
                deactivated += 1
            merged += 1
        self._resorts.flush()
        return MergeSummary(
            merged_count=merged, changed_count=changed, deactivated_count=deactivated
        )

    def merge_resort(self, resort: Resort) -> bool:
        linked = [
            LinkedView(view=view_for_record(record), missing=record.missing_since is not None)
            for record in self._records.list_by_resort(resort.id)
            if record.match_status == "linked"
        ]
        overrides = {o.field: o.value for o in self._overrides.list_by_resort(resort.id)}
        result = compute_merge(
            current_name=resort.name,
            current_country=resort.country,
            current_region=resort.region,
            views=linked,
            overrides=overrides,
            lift_envelope=self._lift_envelope(resort),
        )
        changed = _apply(resort, result)
        resort.last_merged_at = self._clock()
        return changed

    def _lift_envelope(self, resort: Resort) -> tuple[int, int] | None:
        lifts = self._lifts.list_by_resort(resort.id)
        bases = [lift.base_altitude_m for lift in lifts if lift.base_altitude_m is not None]
        tops = [lift.top_altitude_m for lift in lifts if lift.top_altitude_m is not None]
        if not bases or not tops:
            return None
        return round(min(bases)), round(max(tops))


def _apply(resort: Resort, result: MergeResult) -> bool:
    updates: dict[str, Any] = {
        "name": result.name,
        "country": result.country,
        "country_code": result.country_code,
        "region": result.region,
        "region_code": result.region_code,
        "city": result.city,
        "latitude": result.latitude,
        "longitude": result.longitude,
        "boundary": result.boundary,
        "bbox_min_lat": result.bbox[0] if result.bbox else None,
        "bbox_min_lon": result.bbox[1] if result.bbox else None,
        "bbox_max_lat": result.bbox[2] if result.bbox else None,
        "bbox_max_lon": result.bbox[3] if result.bbox else None,
        "elevation_base_m": result.elevation_base_m,
        "elevation_top_m": result.elevation_top_m,
        "is_active": result.is_active,
        "name_aliases": list(result.name_aliases),
        "field_provenance": dict(result.provenance),
    }
    changed = False
    for attr, value in updates.items():
        if getattr(resort, attr) != value:
            setattr(resort, attr, value)
            changed = True
    return changed
