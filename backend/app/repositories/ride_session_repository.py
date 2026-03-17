import uuid

from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.ride_session import RideSession
from app.repositories.base import SqlAlchemyRepository


class RideSessionRepository(SqlAlchemyRepository):
    def __init__(self, db: Session) -> None:
        super().__init__(db)

    def add(self, ride_session: RideSession) -> None:
        self._db.add(ride_session)

    def get_owned_by_user(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession | None:
        stmt = select(RideSession).where(
            RideSession.id == session_id,
            RideSession.user_id == user_id,
        )
        return self._db.scalar(stmt)

    def count_by_user(self, user_id: uuid.UUID) -> int:
        stmt = select(func.count()).select_from(RideSession).where(RideSession.user_id == user_id)
        return int(self._db.scalar(stmt) or 0)

    def list_by_user(self, user_id: uuid.UUID, page: int, page_size: int) -> list[RideSession]:
        stmt = (
            select(RideSession)
            .where(RideSession.user_id == user_id)
            .order_by(RideSession.started_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        return list(self._db.scalars(stmt).all())
