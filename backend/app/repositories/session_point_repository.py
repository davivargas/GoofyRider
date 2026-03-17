import uuid
from collections.abc import Sequence

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.session_point import SessionPoint
from app.repositories.base import SqlAlchemyRepository


class SessionPointRepository(SqlAlchemyRepository):
    def __init__(self, db: Session) -> None:
        super().__init__(db)

    def add_batch(self, points: Sequence[SessionPoint]) -> None:
        self._db.add_all(points)

    def existing_offsets(self, session_id: uuid.UUID, offsets: Sequence[int]) -> set[int]:
        if not offsets:
            return set()

        stmt = select(SessionPoint.t_offset_ms).where(
            SessionPoint.session_id == session_id,
            SessionPoint.t_offset_ms.in_(list(offsets)),
        )
        return set(self._db.scalars(stmt).all())

    def list_by_session(self, session_id: uuid.UUID) -> list[SessionPoint]:
        stmt = (
            select(SessionPoint)
            .where(SessionPoint.session_id == session_id)
            .order_by(SessionPoint.t_offset_ms.asc())
        )
        return list(self._db.scalars(stmt).all())
