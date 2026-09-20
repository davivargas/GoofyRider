from collections.abc import Mapping
from collections.abc import Sequence
from datetime import UTC
from datetime import datetime
from typing import Any
import uuid

from sqlalchemy import delete
from sqlalchemy import func
from sqlalchemy import or_
from sqlalchemy import select
from sqlalchemy.orm import joinedload
from sqlalchemy.orm import selectinload

from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.ride_session_action import RideSessionAction
from app.models.ride_session_override import RideSessionOverride
from app.repositories.base import SqlAlchemyRepository

# The analyzer-owned summary columns, with the value each carries before any
# analysis has run. Keep in sync with `_summary_to_fields` in `SessionService`:
# every field that an analysis writes must be resettable by `clear_analysis`.
_ANALYSIS_SUMMARY_DEFAULTS: Mapping[str, float | int | None] = {
    "total_duration_s": 0.0,
    "descent_duration_s": 0.0,
    "lift_duration_s": 0.0,
    "descent_distance_m": 0.0,
    "lift_distance_m": 0.0,
    "descent_vertical_m": 0.0,
    "lift_vertical_m": 0.0,
    "avg_descent_speed_mps": 0.0,
    "break_count": 0,
    "break_duration_s": 0.0,
    "max_speed_mps": None,
    "peak_altitude_m": None,
    "center_lat": None,
    "center_long": None,
    "altitude_offset_m": None,
}


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

    def clear_analysis(
        self,
        session_id: uuid.UUID,
        *,
        keep_overrides: bool = False,
    ) -> RideSession | None:
        """Undo everything an analysis wrote, back to the pre-analysis state.

        `keep_overrides` retains the override spans. They are rider intent
        rather than derived data — the analyzer only ever echoes them back —
        so a caller that is replacing a session's points, not the session
        itself, keeps them for the next analysis to consume as presets.
        """
        session = self._db.get(RideSession, session_id)
        if session is None:
            return None

        self._db.execute(
            delete(RideSessionAction).where(RideSessionAction.session_id == session_id)
        )
        if not keep_overrides:
            self._db.execute(
                delete(RideSessionOverride).where(RideSessionOverride.session_id == session_id)
            )

        for field_name, default_value in _ANALYSIS_SUMMARY_DEFAULTS.items():
            setattr(session, field_name, default_value)

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

    def find_by_user_resort_and_window(
        self,
        *,
        user_id: uuid.UUID,
        resort_id: uuid.UUID,
        started_at: datetime,
        ended_at: datetime,
    ) -> RideSession | None:
        stmt = select(RideSession).where(
            RideSession.user_id == user_id,
            RideSession.resort_id == resort_id,
            RideSession.started_at == started_at,
            RideSession.ended_at == ended_at,
        )
        return self._db.scalar(stmt)

    def list_needing_reanalysis(self, current_version: str, *, limit: int) -> list[RideSession]:
        stmt = (
            select(RideSession)
            .where(
                RideSession.status == RideSessionStatus.COMPLETED,
                or_(
                    RideSession.processed_by_version.is_(None),
                    RideSession.processed_by_version != current_version,
                ),
            )
            .order_by(RideSession.created_at.asc())
            .limit(limit)
        )
        return list(self._db.scalars(stmt).all())
