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
