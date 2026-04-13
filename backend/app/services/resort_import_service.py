from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from typing import TypeVar

from app.models.resort import Resort
from app.repositories.protocols import ResortRepositoryProtocol
from app.services.ski_api_resort_source import ExternalResortRecord
from app.services.ski_api_resort_source import ExternalResortSourceProtocol

T = TypeVar("T")


@dataclass(frozen=True)
class ResortImportSummary:
    created_count: int
    updated_count: int
    deactivated_count: int


class ResortImportService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        resort_source: ExternalResortSourceProtocol,
        deactivate_missing: bool = False,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._resort_repository = resort_repository
        self._resort_source = resort_source
        self._deactivate_missing = deactivate_missing
        self._clock = clock or _utc_now

    def import_resorts(self) -> ResortImportSummary:
        imported_at = self._clock()
        external_resorts = self._resort_source.fetch_resorts()
        if self._deactivate_missing:
            _ensure_single_external_source(external_resorts)

        created_count = 0
        updated_count = 0
        seen_external_ids: set[str] = set()

        for external_resort in external_resorts:
            seen_external_ids.add(external_resort.external_id)
            existing_resort = self._find_existing_resort(external_resort)

            if existing_resort is None:
                self._resort_repository.add(
                    _build_new_resort(
                        external_resort=external_resort,
                        imported_at=imported_at,
                    )
                )
                created_count += 1
                continue

            _apply_external_resort(
                resort=existing_resort,
                external_resort=external_resort,
                imported_at=imported_at,
            )
            updated_count += 1

        deactivated_count = 0
        if self._deactivate_missing:
            deactivated_count = self._deactivate_missing_resorts(
                imported_at=imported_at,
                seen_external_ids=seen_external_ids,
                external_source=_detect_external_source(external_resorts),
            )
        self._resort_repository.commit()

        return ResortImportSummary(
            created_count=created_count,
            updated_count=updated_count,
            deactivated_count=deactivated_count,
        )

    def _find_existing_resort(self, external_resort: ExternalResortRecord) -> Resort | None:
        by_external_ref = self._resort_repository.get_by_external_ref(
            external_source=external_resort.external_source,
            external_id=external_resort.external_id,
        )
        if by_external_ref is not None:
            return by_external_ref

        by_identity = self._resort_repository.get_by_name_country_region(
            name=external_resort.name,
            country=external_resort.country,
            region=external_resort.region,
        )
        if by_identity is not None:
            return by_identity

        return None

    def _deactivate_missing_resorts(
        self,
        imported_at: datetime,
        seen_external_ids: set[str],
        external_source: str | None,
    ) -> int:
        if external_source is None:
            return 0

        deactivated_count = 0
        tracked_resorts = self._resort_repository.list_by_external_source(external_source)
        for resort in tracked_resorts:
            if resort.external_id in seen_external_ids:
                continue
            if not resort.is_active:
                continue

            resort.is_active = False
            resort.last_source_sync_at = imported_at
            deactivated_count += 1

        return deactivated_count


def _build_new_resort(
    external_resort: ExternalResortRecord,
    imported_at: datetime,
) -> Resort:
    return Resort(
        name=external_resort.name,
        country=external_resort.country,
        region=external_resort.region,
        city=external_resort.city,
        latitude=external_resort.latitude,
        longitude=external_resort.longitude,
        elevation_base_m=external_resort.elevation_base_m,
        elevation_top_m=external_resort.elevation_top_m,
        external_source=external_resort.external_source,
        external_id=external_resort.external_id,
        last_source_sync_at=imported_at,
        is_active=True,
    )


def _apply_external_resort(
    resort: Resort,
    external_resort: ExternalResortRecord,
    imported_at: datetime,
) -> None:
    resort.name = external_resort.name
    resort.country = external_resort.country
    resort.region = external_resort.region
    resort.city = external_resort.city or resort.city
    resort.latitude = _prefer_external_value(external_resort.latitude, resort.latitude)
    resort.longitude = _prefer_external_value(external_resort.longitude, resort.longitude)
    resort.elevation_base_m = _prefer_external_value(
        external_resort.elevation_base_m,
        resort.elevation_base_m,
    )
    resort.elevation_top_m = _prefer_external_value(
        external_resort.elevation_top_m,
        resort.elevation_top_m,
    )
    resort.external_source = external_resort.external_source
    resort.external_id = external_resort.external_id
    resort.last_source_sync_at = imported_at
    resort.is_active = True


def _detect_external_source(external_resorts: list[ExternalResortRecord]) -> str | None:
    if not external_resorts:
        return None
    return external_resorts[0].external_source


def _ensure_single_external_source(external_resorts: list[ExternalResortRecord]) -> None:
    external_sources = {resort.external_source for resort in external_resorts}
    if len(external_sources) <= 1:
        return

    ordered_sources = ", ".join(sorted(external_sources))
    raise ValueError(
        "Mixed external sources are not supported when deactivate_missing is enabled: "
        f"{ordered_sources}"
    )


def _prefer_external_value(external_value: T | None, existing_value: T | None) -> T | None:
    if external_value is None:
        return existing_value
    return external_value


def _utc_now() -> datetime:
    return datetime.now(UTC)
