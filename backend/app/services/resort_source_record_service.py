"""Pass 1 of the import: raw source records in, change detection, missing marking (spec 5.3)."""

from __future__ import annotations

from collections.abc import Callable
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
import logging

from app.models.resort_source_record import ResortSourceRecord
from app.repositories.protocols import ResortSourceRecordRepositoryProtocol
from app.services.catalog_types import SOURCE_SKI_API
from app.services.catalog_types import ExternalSourceRecord
from app.services.catalog_types import content_hash
from app.services.exceptions import ValidationError

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RecordUpsertSummary:
    created: int
    updated: int
    unchanged: int
    marked_missing: int


class ResortSourceRecordService:
    def __init__(
        self,
        record_repository: ResortSourceRecordRepositoryProtocol,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._records = record_repository
        self._clock = clock or (lambda: datetime.now(UTC))

    def upsert_records(
        self,
        source: str,
        records: Iterable[ExternalSourceRecord],
        run_started_at: datetime,
        *,
        mark_missing: bool = True,
    ) -> RecordUpsertSummary:
        created = updated = unchanged = 0
        seen: set[str] = set()
        for external in records:
            if external.source != source:
                raise ValidationError(
                    f"Record source {external.source!r} does not match {source!r}."
                )
            seen.add(external.external_id)
            existing = self._records.get_by_source_and_external_id(source, external.external_id)
            if existing is None:
                self._records.add(
                    ResortSourceRecord(
                        source=source,
                        external_id=external.external_id,
                        payload=external.payload,
                        content_hash=external.content_hash,
                        fetched_at=self._clock(),
                        snapshot_built_at=external.snapshot_built_at,
                        resort_id=None,
                        match_status="pending_review",
                        match_method=None,
                    )
                )
                created += 1
                continue
            existing.missing_since = None
            has_detail = existing.source == SOURCE_SKI_API and "detail" in existing.payload
            comparison_hash = (
                content_hash({k: v for k, v in existing.payload.items() if k != "detail"})
                if has_detail
                else existing.content_hash
            )
            if comparison_hash == external.content_hash:
                unchanged += 1
                continue
            if has_detail:
                existing.payload = {**external.payload, "detail": existing.payload["detail"]}
                existing.content_hash = content_hash(existing.payload)
            else:
                existing.payload = external.payload
                existing.content_hash = external.content_hash
            existing.fetched_at = self._clock()
            existing.snapshot_built_at = external.snapshot_built_at
            updated += 1
        self._records.flush()
        if mark_missing:
            marked_missing = self._records.mark_missing_except(source, seen, run_started_at)
        else:
            # A filtered run only ever sees part of the catalog, so "not seen" does not mean
            # "gone from the source"; marking would deactivate the whole out-of-filter catalog.
            marked_missing = 0
            logger.info("Filtered run: missing-marking disabled for %s", source)
        logger.info(
            "%s records: created=%d updated=%d unchanged=%d missing=%d",
            source,
            created,
            updated,
            unchanged,
            marked_missing,
        )
        return RecordUpsertSummary(created, updated, unchanged, marked_missing)
