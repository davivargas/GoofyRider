"""Operator resolutions for pending source records (spec 7.1)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
import uuid

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import ResortSourceRecordRepositoryProtocol
from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_merge_service import view_for_record


@dataclass(frozen=True)
class PendingItem:
    source: str
    external_id: str
    name: str | None
    candidates: list[dict[str, Any]]


class ResortReviewService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        record_repository: ResortSourceRecordRepositoryProtocol,
        merge_service: ResortMergeService,
        lift_sync_service: ResortLiftSyncService,
    ) -> None:
        self._resorts = resort_repository
        self._records = record_repository
        self._merge = merge_service
        self._lift_sync = lift_sync_service

    def list_pending(self, source: str | None) -> list[PendingItem]:
        items: list[PendingItem] = []
        for record in self._records.list_pending_review(source):
            view = view_for_record(record)
            items.append(
                PendingItem(
                    record.source,
                    record.external_id,
                    view.name,
                    list(record.match_candidates or []),
                )
            )
        return items

    def link(self, source: str, external_id: str, resort_id: uuid.UUID) -> None:
        record = self._pending_record(source, external_id)
        resort = self._resorts.get_by_id(resort_id)
        if resort is None:
            raise NotFoundError("Resort not found.")
        if source == SOURCE_OPENSKIDATA and any(
            r.source == SOURCE_OPENSKIDATA and r.match_status == "linked"
            for r in self._records.list_by_resort(resort.id)
        ):
            raise ConflictError("Resort already has an OpenSkiData record.")
        self._link(record, resort)

    def reject(self, source: str, external_id: str) -> None:
        record = self._pending_record(source, external_id)
        record.match_status = "rejected"
        record.match_method = None
        record.resort_id = None
        record.match_candidates = None
        self._records.commit()

    def create(self, source: str, external_id: str) -> uuid.UUID:
        record = self._pending_record(source, external_id)
        view = view_for_record(record)
        resort = Resort(
            id=uuid.uuid4(),
            name=view.name or external_id,
            country=view.country or "Unknown",
            region=view.region or "Unknown",
            city=view.city,
            latitude=view.latitude,
            longitude=view.longitude,
            country_code=view.country_code,
            region_code=view.region_code,
            is_active=True,
            name_aliases=[],
            field_provenance={},
        )
        self._resorts.add(resort)
        self._resorts.flush()
        self._link(record, resort)
        return resort.id

    def _pending_record(self, source: str, external_id: str) -> ResortSourceRecord:
        record = self._records.get_by_source_and_external_id(source, external_id)
        if record is None:
            raise NotFoundError("Source record not found.")
        if record.match_status != "pending_review":
            raise ValidationError("Source record is not pending review.")
        return record

    def _link(self, record: ResortSourceRecord, resort: Resort) -> None:
        record.resort_id = resort.id
        record.match_status = "linked"
        record.match_method = "manual"
        record.match_candidates = None
        self._records.flush()
        self._merge.merge_resort(resort)
        self._resorts.commit()
