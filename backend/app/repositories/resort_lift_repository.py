from collections.abc import Sequence
import uuid

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
            count += 1
        return count
