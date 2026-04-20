from collections.abc import Sequence
import uuid

from sqlalchemy import delete
from sqlalchemy import select

from app.models.ride_session_action import RideSessionAction
from app.repositories.base import SqlAlchemyRepository


class SessionActionRepository(SqlAlchemyRepository):
    def add(self, action: RideSessionAction) -> None:
        self._db.add(action)

    def add_batch(self, actions: Sequence[RideSessionAction]) -> None:
        self._db.add_all(list(actions))

    def list_by_session(self, session_id: uuid.UUID) -> list[RideSessionAction]:
        stmt = (
            select(RideSessionAction)
            .where(RideSessionAction.session_id == session_id)
            .order_by(RideSessionAction.started_at.asc())
        )
        return list(self._db.scalars(stmt).all())

    def delete_by_session(self, session_id: uuid.UUID) -> int:
        result = self._db.execute(
            delete(RideSessionAction).where(RideSessionAction.session_id == session_id)
        )
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)
