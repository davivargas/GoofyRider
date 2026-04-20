from collections.abc import Sequence
import uuid

from sqlalchemy import delete
from sqlalchemy import select

from app.models.ride_session_override import RideSessionOverride
from app.repositories.base import SqlAlchemyRepository


class SessionOverrideRepository(SqlAlchemyRepository):
    def add(self, override: RideSessionOverride) -> None:
        self._db.add(override)

    def add_batch(self, overrides: Sequence[RideSessionOverride]) -> None:
        self._db.add_all(list(overrides))

    def list_by_session(self, session_id: uuid.UUID) -> list[RideSessionOverride]:
        stmt = (
            select(RideSessionOverride)
            .where(RideSessionOverride.session_id == session_id)
            .order_by(RideSessionOverride.started_at.asc())
        )
        return list(self._db.scalars(stmt).all())

    def delete_by_session(self, session_id: uuid.UUID) -> int:
        result = self._db.execute(
            delete(RideSessionOverride).where(RideSessionOverride.session_id == session_id)
        )
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)
