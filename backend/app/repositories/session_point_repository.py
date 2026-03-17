from collections.abc import Sequence

from sqlalchemy.orm import Session

from app.models.session_point import SessionPoint
from app.repositories.base import SqlAlchemyRepository


class SessionPointRepository(SqlAlchemyRepository):
    def __init__(self, db: Session) -> None:
        super().__init__(db)

    def add_batch(self, points: Sequence[SessionPoint]) -> None:
        self._db.add_all(points)
