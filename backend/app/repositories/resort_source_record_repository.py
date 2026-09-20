from collections.abc import Collection
from datetime import datetime
import logging
import uuid

from sqlalchemy import Text
from sqlalchemy import cast
from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy import update
from sqlalchemy.dialects.postgresql import ARRAY

from app.models.resort_source_record import ResortSourceRecord
from app.repositories.base import SqlAlchemyRepository

logger = logging.getLogger(__name__)


class ResortSourceRecordRepository(SqlAlchemyRepository):
    def get_by_source_and_external_id(
        self, source: str, external_id: str
    ) -> ResortSourceRecord | None:
        stmt = select(ResortSourceRecord).where(
            ResortSourceRecord.source == source, ResortSourceRecord.external_id == external_id
        )
        return self._db.scalar(stmt)

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortSourceRecord]:
        stmt = (
            select(ResortSourceRecord)
            .where(ResortSourceRecord.resort_id == resort_id)
            .order_by(ResortSourceRecord.source.asc(), ResortSourceRecord.external_id.asc())
        )
        return list(self._db.scalars(stmt).all())

    def list_by_source(self, source: str) -> list[ResortSourceRecord]:
        stmt = (
            select(ResortSourceRecord)
            .where(ResortSourceRecord.source == source)
            .order_by(ResortSourceRecord.external_id.asc())
        )
        return list(self._db.scalars(stmt).all())

    def list_pending_review(self, source: str | None = None) -> list[ResortSourceRecord]:
        stmt = select(ResortSourceRecord).where(ResortSourceRecord.match_status == "pending_review")
        if source is not None:
            stmt = stmt.where(ResortSourceRecord.source == source)
        stmt = stmt.order_by(ResortSourceRecord.source.asc(), ResortSourceRecord.external_id.asc())
        return list(self._db.scalars(stmt).all())

    def list_unlinked(self, source: str) -> list[ResortSourceRecord]:
        stmt = (
            select(ResortSourceRecord)
            .where(
                ResortSourceRecord.source == source,
                ResortSourceRecord.match_status == "pending_review",
                ResortSourceRecord.resort_id.is_(None),
            )
            .order_by(ResortSourceRecord.external_id.asc())
        )
        return list(self._db.scalars(stmt).all())

    def list_legacy_with_candidates(self) -> list[ResortSourceRecord]:
        stmt = (
            select(ResortSourceRecord)
            .where(
                ResortSourceRecord.match_method == "legacy",
                ResortSourceRecord.match_candidates.is_not(None),
            )
            .order_by(ResortSourceRecord.external_id.asc())
        )
        return list(self._db.scalars(stmt).all())

    def add(self, record: ResortSourceRecord) -> None:
        self._db.add(record)

    def mark_missing_except(
        self, source: str, seen_external_ids: Collection[str], missing_since: datetime
    ) -> int:
        if not seen_external_ids:
            # An empty snapshot is a failed fetch, not an emptied catalog: marking here would
            # take the whole source out of service.
            logger.warning("Refusing to mark every %s record missing: no ids were seen.", source)
            return 0
        # One array bind instead of one literal per id: the full catalog is ~12k ski areas.
        seen = select(func.unnest(cast(list(seen_external_ids), ARRAY(Text))))
        stmt = (
            update(ResortSourceRecord)
            .where(
                ResortSourceRecord.source == source,
                ResortSourceRecord.missing_since.is_(None),
                ResortSourceRecord.external_id.not_in(seen),
            )
            .values(missing_since=missing_since)
        )
        result = self._db.execute(stmt)
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)

    def flush(self) -> None:
        self._db.flush()
