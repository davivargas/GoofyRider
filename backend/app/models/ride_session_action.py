from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING
import uuid

from sqlalchemy import CheckConstraint
from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Integer
from sqlalchemy import Numeric
from sqlalchemy import SmallInteger
from sqlalchemy import Text
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.models.base import Base

if TYPE_CHECKING:
    from app.models.ride_session import RideSession


class RideSessionAction(Base):
    __tablename__ = "ride_session_actions"
    __table_args__ = (
        CheckConstraint("action_type IN ('lift','run')", name="ck_ride_session_actions_action_type"),
        CheckConstraint("sequence_index >= 1", name="ck_ride_session_actions_sequence_index"),
        CheckConstraint("time_of_day IN (1,2,3)", name="ck_ride_session_actions_time_of_day"),
        CheckConstraint(
            "source IN ('live_analyzer','slopes_import','manual')",
            name="ck_ride_session_actions_source",
        ),
        UniqueConstraint(
            "session_id",
            "action_type",
            "sequence_index",
            name="uq_ride_session_actions_session_id_action_type_sequence_index",
        ),
        Index("ix_ride_session_actions_session_id_started_at", "session_id", "started_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("ride_sessions.id", ondelete="CASCADE"),
        nullable=False,
    )
    action_type: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    sequence_index: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
    )
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    ended_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    duration_s: Mapped[float] = mapped_column(
        Numeric(10, 3, asdecimal=False),
        nullable=False,
    )
    distance_m: Mapped[float] = mapped_column(
        Numeric(10, 2, asdecimal=False),
        nullable=False,
    )
    avg_speed_mps: Mapped[float] = mapped_column(
        Numeric(7, 4, asdecimal=False),
        nullable=False,
    )
    min_speed_mps: Mapped[float | None] = mapped_column(
        Numeric(7, 4, asdecimal=False),
        nullable=True,
    )
    max_speed_mps: Mapped[float] = mapped_column(
        Numeric(7, 4, asdecimal=False),
        nullable=False,
    )
    vertical_m: Mapped[float | None] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=True,
    )
    min_altitude_m: Mapped[float | None] = mapped_column(
        Numeric(9, 2, asdecimal=False),
        nullable=True,
    )
    max_altitude_m: Mapped[float | None] = mapped_column(
        Numeric(9, 2, asdecimal=False),
        nullable=True,
    )
    min_lat: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    max_lat: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    min_long: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    max_long: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    top_speed_lat: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    top_speed_long: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    top_speed_alt_m: Mapped[float | None] = mapped_column(
        Numeric(9, 2, asdecimal=False),
        nullable=True,
    )
    time_of_day: Mapped[int | None] = mapped_column(
        SmallInteger,
        nullable=True,
    )
    external_track_id: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    source: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    session: Mapped["RideSession"] = relationship(
        "RideSession",
        back_populates="actions",
    )

