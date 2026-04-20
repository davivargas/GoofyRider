from collections.abc import Mapping
from collections.abc import Sequence
from datetime import UTC
from datetime import datetime
from typing import Any
import uuid

from sqlalchemy import delete
from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.orm import selectinload

from app.models.ride_session import RideSession
from app.models.ride_session_action import RideSessionAction
from app.models.ride_session_override import RideSessionOverride
from app.repositories.base import SqlAlchemyRepository


class RideSessionRepository(SqlAlchemyRepository):
    def add(self, ride_session: RideSession) -> None:
        self._db.add(ride_session)

    def delete(self, ride_session: RideSession) -> None:
        self._db.delete(ride_session)

    def get_owned_by_user(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession | None:
        stmt = (
            select(RideSession)
            .options(joinedload(RideSession.resort))
            .where(
                RideSession.id == session_id,
                RideSession.user_id == user_id,
            )
        )
        return self._db.scalar(stmt)

    def count_by_user(self, user_id: uuid.UUID) -> int:
        stmt = select(func.count()).select_from(RideSession).where(RideSession.user_id == user_id)
        return int(self._db.scalar(stmt) or 0)

    def list_by_user(self, user_id: uuid.UUID, page: int, page_size: int) -> list[RideSession]:
        stmt = (
            select(RideSession)
            .options(joinedload(RideSession.resort))
            .where(RideSession.user_id == user_id)
            .order_by(RideSession.started_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        return list(self._db.scalars(stmt).all())

    def list_by_user_with_count(
        self, user_id: uuid.UUID, page: int, page_size: int
    ) -> tuple[list[RideSession], int]:
        count_stmt = (
            select(func.count()).select_from(RideSession).where(RideSession.user_id == user_id)
        )
        total = int(self._db.scalar(count_stmt) or 0)

        list_stmt = (
            select(RideSession)
            .options(joinedload(RideSession.resort))
            .where(RideSession.user_id == user_id)
            .order_by(RideSession.started_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        sessions = list(self._db.scalars(list_stmt).all())
        return sessions, total

    def update_analysis_result(
        self,
        session_id: uuid.UUID,
        summary_fields: Mapping[str, Any],
        actions: Sequence[RideSessionAction],
        overrides: Sequence[RideSessionOverride],
        *,
        version: str,
    ) -> RideSession | None:
        session = self._db.get(RideSession, session_id)
        if session is None:
            return None

        for field_name, value in summary_fields.items():
            setattr(session, field_name, value)

        session.processed_by_version = version
        session.processed_at = datetime.now(UTC)

        self._db.execute(
            delete(RideSessionAction).where(RideSessionAction.session_id == session_id)
        )
        self._db.execute(
            delete(RideSessionOverride).where(RideSessionOverride.session_id == session_id)
        )

        for action in actions:
            action.session_id = session_id
            self._db.add(action)
        for override in overrides:
            override.session_id = session_id
            self._db.add(override)

        return session

    def clear_analysis(self, session_id: uuid.UUID) -> RideSession | None:
        session = self._db.get(RideSession, session_id)
        if session is None:
            return None

        self._db.execute(
            delete(RideSessionAction).where(RideSessionAction.session_id == session_id)
        )
        self._db.execute(
            delete(RideSessionOverride).where(RideSessionOverride.session_id == session_id)
        )

        session.processed_by_version = None
        session.processed_at = None
        return session

    def get_detail_with_actions(self, session_id: uuid.UUID) -> RideSession | None:
        stmt = (
            select(RideSession)
            .options(
                joinedload(RideSession.resort),
                selectinload(RideSession.actions),
                selectinload(RideSession.overrides),
            )
            .where(RideSession.id == session_id)
        )
        return self._db.scalar(stmt)
