from collections.abc import Collection
from collections.abc import Sequence
import uuid

from sqlalchemy import delete
from sqlalchemy import select

from app.models.resort_lift import ResortLift
from app.repositories.base import SqlAlchemyRepository


class ResortLiftRepository(SqlAlchemyRepository):
    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortLift]:
        stmt = (
            select(ResortLift)
            .where(ResortLift.resort_id == resort_id)
            .order_by(ResortLift.name.asc())
        )
        return list(self._db.scalars(stmt).all())

    def match_track_id(self, track_id: str) -> ResortLift | None:
        stmt = select(ResortLift).where(ResortLift.external_track_id == track_id)
        return self._db.scalars(stmt).first()

    def upsert_by_external_track_id(self, resort_id: uuid.UUID, rows: Sequence[ResortLift]) -> int:
        count = 0
        for row in rows:
            if row.external_track_id is None:
                continue
            existing = self._db.scalars(
                select(ResortLift).where(
                    ResortLift.resort_id == resort_id,
                    ResortLift.external_track_id == row.external_track_id,
                )
            ).first()
            if existing is None:
                row.resort_id = resort_id
                self._db.add(row)
            else:
                existing.name = row.name
                existing.lift_type = row.lift_type
                existing.osm_aerialway = row.osm_aerialway
                existing.polyline = row.polyline
                existing.base_altitude_m = row.base_altitude_m
                existing.top_altitude_m = row.top_altitude_m
                existing.status = row.status
                if row.source is not None:
                    existing.source = row.source
                existing.source_record_id = row.source_record_id
            # Flush so a second row in this batch with the same
            # external_track_id sees the first as `existing` instead of
            # inserting a duplicate.
            self._db.flush()
            count += 1
        return count

    def delete_missing_for_resort(
        self, resort_id: uuid.UUID, keep_track_ids: Collection[str], source: str
    ) -> int:
        stmt = delete(ResortLift).where(
            ResortLift.resort_id == resort_id,
            ResortLift.source == source,
            ResortLift.external_track_id.not_in(list(keep_track_ids)),
        )
        result = self._db.execute(stmt)
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)

    def delete_by_source_for_resort(self, resort_id: uuid.UUID, source: str) -> int:
        stmt = delete(ResortLift).where(
            ResortLift.resort_id == resort_id, ResortLift.source == source
        )
        result = self._db.execute(stmt)
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)
