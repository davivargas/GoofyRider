from collections.abc import Sequence
import uuid

from sqlalchemy import select

from app.models.session_point import SessionPoint
from app.repositories.base import SqlAlchemyRepository


class SessionPointRepository(SqlAlchemyRepository):
    def add_batch(self, points: Sequence[SessionPoint]) -> None:
        self._db.add_all(points)

    def existing_elapsed_offsets_ms(
        self,
        session_id: uuid.UUID,
        elapsed_offsets_ms: Sequence[int],
    ) -> set[int]:
        if not elapsed_offsets_ms:
            return set()

        stmt = select(SessionPoint.t_offset_ms).where(
            SessionPoint.session_id == session_id,
            SessionPoint.t_offset_ms.in_(list(elapsed_offsets_ms)),
        )
        return set(self._db.scalars(stmt).all())

    def list_by_session(self, session_id: uuid.UUID) -> list[SessionPoint]:
        stmt = (
            select(SessionPoint)
            .where(SessionPoint.session_id == session_id)
            .order_by(SessionPoint.t_offset_ms.asc())
        )
        return list(self._db.scalars(stmt).all())
