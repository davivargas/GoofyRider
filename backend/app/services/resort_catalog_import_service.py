"""Orchestrates one catalog import: records, linking, merge, lifts (spec 5.5, 7.1)."""

from __future__ import annotations

from collections.abc import Callable
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
import logging
from typing import Protocol
import uuid

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.protocols import ResortFieldOverrideRepositoryProtocol
from app.repositories.protocols import ResortLiftRepositoryProtocol
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import ResortSourceRecordRepositoryProtocol
from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import ExternalLiftRecord
from app.services.catalog_types import ExternalSourceRecord
from app.services.catalog_types import SourceResortView
from app.services.resort_lift_sync_service import LiftSyncSummary
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_matching import MatchKind
from app.services.resort_matching import MatchQuery
from app.services.resort_matching import ResortCandidate
from app.services.resort_matching import match_resort
from app.services.resort_merge_service import TEXT_FIELD_LIMITS
from app.services.resort_merge_service import MergeSummary
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_merge_service import view_for_record
from app.services.resort_plausibility import clamp_text
from app.services.resort_source_record_service import RecordUpsertSummary
from app.services.resort_source_record_service import ResortSourceRecordService

logger = logging.getLogger(__name__)


class OpenSkiDataSourceProtocol(Protocol):
    @property
    def countries(self) -> frozenset[str] | None: ...

    def snapshot_built_at(self) -> datetime | None: ...

    def iter_ski_areas(self) -> Iterator[ExternalSourceRecord]: ...

    def iter_lifts(self) -> Iterator[ExternalLiftRecord]: ...


@dataclass(frozen=True)
class CatalogImportOptions:
    rematch: bool = False
    dry_run: bool = False


@dataclass(frozen=True)
class CatalogImportSummary:
    records: RecordUpsertSummary
    linked_auto: int
    linked_primary: int
    pending_review: int
    merge: MergeSummary
    lifts: LiftSyncSummary | None


class ResortCatalogImportService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        record_repository: ResortSourceRecordRepositoryProtocol,
        override_repository: ResortFieldOverrideRepositoryProtocol,
        lift_repository: ResortLiftRepositoryProtocol,
        record_service: ResortSourceRecordService,
        merge_service: ResortMergeService,
        lift_sync_service: ResortLiftSyncService,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._resorts = resort_repository
        self._records = record_repository
        self._overrides = override_repository
        self._lifts = lift_repository
        self._record_service = record_service
        self._merge_service = merge_service
        self._lift_sync = lift_sync_service
        self._clock = clock or (lambda: datetime.now(UTC))

    def import_openskidata(
        self, source: OpenSkiDataSourceProtocol, options: CatalogImportOptions
    ) -> CatalogImportSummary:
        run_started_at = self._clock()
        records = self._record_service.upsert_records(
            SOURCE_OPENSKIDATA,
            source.iter_ski_areas(),
            run_started_at,
            mark_missing=source.countries is None,
        )
        auto, primary, pending = self.link_records(SOURCE_OPENSKIDATA, options)
        self.review_legacy_resorts()
        merge = self._merge_service.merge_stale()
        lifts = self._lift_sync.sync(source.iter_lifts())
        if options.dry_run:
            self._records.rollback()
            logger.info("Dry run: rolled back catalog import.")
        else:
            self._resorts.commit()
        return CatalogImportSummary(records, auto, primary, pending, merge, lifts)

    def link_records(self, source: str, options: CatalogImportOptions) -> tuple[int, int, int]:
        """Link every matchable record of `source`. Candidate pool is built once per call."""
        auto = primary = pending = 0
        is_openskidata = source == SOURCE_OPENSKIDATA
        primary_ids: set[uuid.UUID] = (
            {
                r.resort_id
                for r in self._records.list_by_source(SOURCE_OPENSKIDATA)
                if r.match_status == "linked" and r.resort_id is not None
            }
            if is_openskidata
            else set()
        )
        pool: dict[uuid.UUID, ResortCandidate] = {
            resort.id: _candidate_from_resort(resort, has_primary=resort.id in primary_ids)
            for resort in self._resorts.list_all_for_matching()
        }
        # Kept in step with the links made below instead of rebuilt from `pool` per record:
        # every resort a record may still claim. `match_resort` breaks ties on resort_id, so
        # the set's iteration order does not affect any decision.
        eligible_ids = set(pool) - primary_ids if is_openskidata else set(pool)
        for record in self._records.list_by_source(source):
            if not _should_match(record, options):
                continue
            if is_openskidata and record.resort_id is not None:
                primary_ids.discard(record.resort_id)  # re-matching an auto link frees its resort
                if record.resort_id in pool:
                    eligible_ids.add(record.resort_id)
            decision = match_resort(
                _query_for(view_for_record(record)), [pool[rid] for rid in eligible_ids]
            )
            if decision.kind is MatchKind.AUTO and decision.resort_id is not None:
                _link(record, decision.resort_id, "auto", decision.score)
                if is_openskidata:
                    primary_ids.add(decision.resort_id)
                    eligible_ids.discard(decision.resort_id)
                auto += 1
            elif decision.kind is MatchKind.NONE and is_openskidata:
                resort = _new_resort(view_for_record(record))
                self._resorts.add(resort)
                self._resorts.flush()
                _link(record, resort.id, "primary", None)
                primary_ids.add(resort.id)
                pool[resort.id] = _candidate_from_resort(resort, has_primary=True)
                primary += 1
            else:
                record.match_status = "pending_review"
                record.match_method = None
                record.resort_id = None
                record.match_score = decision.score
                record.match_candidates = [c.to_json() for c in decision.candidates]
                pending += 1
            self._records.flush()
        return auto, primary, pending

    def review_legacy_resorts(self) -> int:
        """Legacy rows with no OpenSkiData link get candidate OpenSkiData records (spec 5.5)."""
        osd_records = self._records.list_by_source(SOURCE_OPENSKIDATA)
        if not osd_records:
            return 0
        by_id = {r.id: r for r in osd_records}
        candidates = [_candidate_from_record(r) for r in osd_records]
        reviewed = 0
        for resort in self._resorts.list_without_source(SOURCE_OPENSKIDATA):
            legacy_records = [
                r for r in self._records.list_by_resort(resort.id) if r.match_method == "legacy"
            ]
            if not legacy_records:
                continue
            query = MatchQuery(
                name=resort.name,
                latitude=resort.latitude,
                longitude=resort.longitude,
                country_code=resort.country_code,
            )
            decision = match_resort(query, candidates, legacy_must_review=True)
            payload = [
                {
                    **c.to_json(),
                    "external_id": by_id[c.resort_id].external_id,
                    "linked_resort_id": (
                        str(by_id[c.resort_id].resort_id)
                        if by_id[c.resort_id].resort_id is not None
                        else None
                    ),
                }
                for c in decision.candidates
            ]
            for legacy in legacy_records:
                legacy.match_candidates = payload
                legacy.match_score = decision.score
            reviewed += 1
        self._records.flush()
        return reviewed


def _query_for(view: SourceResortView) -> MatchQuery:
    return MatchQuery(
        name=view.name,
        latitude=view.latitude,
        longitude=view.longitude,
        country_code=view.country_code,
        boundary=view.boundary,
    )


def _should_match(record: ResortSourceRecord, options: CatalogImportOptions) -> bool:
    if record.match_status == "rejected":
        return False
    if record.match_status == "linked":
        return options.rematch and record.match_method == "auto"
    return True


def _link(
    record: ResortSourceRecord, resort_id: uuid.UUID, method: str, score: float | None
) -> None:
    record.resort_id = resort_id
    record.match_status = "linked"
    record.match_method = method
    record.match_score = score
    record.match_candidates = None


def _new_resort(view: SourceResortView) -> Resort:
    return Resort(
        id=uuid.uuid4(),
        name=clamp_text(view.name, TEXT_FIELD_LIMITS["name"]) or "Unnamed ski area",
        country=clamp_text(view.country, TEXT_FIELD_LIMITS["country"]) or "Unknown",
        region=clamp_text(view.region, TEXT_FIELD_LIMITS["region"]) or "Unknown",
        city=clamp_text(view.city, TEXT_FIELD_LIMITS["city"]),
        latitude=view.latitude,
        longitude=view.longitude,
        country_code=view.country_code,
        region_code=clamp_text(view.region_code, TEXT_FIELD_LIMITS["region_code"]),
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )


def _candidate_from_resort(resort: Resort, *, has_primary: bool) -> ResortCandidate:
    bbox = None
    if (
        resort.bbox_min_lat is not None
        and resort.bbox_min_lon is not None
        and resort.bbox_max_lat is not None
        and resort.bbox_max_lon is not None
    ):
        bbox = (
            float(resort.bbox_min_lat),
            float(resort.bbox_min_lon),
            float(resort.bbox_max_lat),
            float(resort.bbox_max_lon),
        )
    return ResortCandidate(
        resort_id=resort.id,
        name=resort.name,
        name_aliases=tuple(resort.name_aliases or []),
        latitude=resort.latitude,
        longitude=resort.longitude,
        bbox=bbox,
        boundary=resort.boundary,
        country_code=resort.country_code,
        has_primary_record=has_primary,
    )


def _candidate_from_record(record: ResortSourceRecord) -> ResortCandidate:
    view = view_for_record(record)
    return ResortCandidate(
        resort_id=record.id,
        name=view.name or record.external_id,
        name_aliases=(),
        latitude=view.latitude,
        longitude=view.longitude,
        bbox=view.bbox,
        boundary=view.boundary,
        country_code=view.country_code,
        has_primary_record=False,
    )
