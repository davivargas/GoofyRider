from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import TYPE_CHECKING
import uuid

from sqlalchemy import DateTime
from sqlalchemy import Enum as SqlEnum
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Numeric
from sqlalchemy import Text
from sqlalchemy import func
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.models.base import Base

if TYPE_CHECKING:
    from app.models.resort import Resort
    from app.models.ride_session_action import RideSessionAction
    from app.models.ride_session_override import RideSessionOverride


class RideSessionStatus(str, Enum):
    DRAFT = "DRAFT"
    COMPLETED = "COMPLETED"
    SYNCED = "SYNCED"


class SessionCondition(str, Enum):
    PACKED = "PACKED"
    WET = "WET"
    GRANULAR = "GRANULAR"
    GROOMED = "GROOMED"
    POWDER = "POWDER"


class RideSession(Base):
    __tablename__ = "ride_sessions"
    __table_args__ = (
        Index("ix_ride_sessions_user_id_started_at", "user_id", "started_at"),
        Index(
            "ix_ride_sessions_external_identifier_unique",
            "external_identifier",
            unique=True,
            postgresql_where=text("external_identifier IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    resort_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("resorts.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    max_speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    source: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default="live_recording",
        server_default=text("'live_recording'"),
    )
    external_identifier: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    conditions: Mapped[SessionCondition | None] = mapped_column(
        SqlEnum(
            SessionCondition,
            name="session_conditions",
            create_type=False,
            validate_strings=True,
        ),
        nullable=True,
    )
    sport: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default="snowboard",
        server_default=text("'snowboard'"),
    )
    altitude_offset_m: Mapped[float | None] = mapped_column(
        Numeric(6, 2, asdecimal=False),
        nullable=True,
    )
    peak_altitude_m: Mapped[float | None] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=True,
    )
    center_lat: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    center_long: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    descent_distance_m: Mapped[float] = mapped_column(
        Numeric(10, 2, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    descent_duration_s: Mapped[float] = mapped_column(
        Numeric(10, 3, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    descent_vertical_m: Mapped[float] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    lift_distance_m: Mapped[float] = mapped_column(
        Numeric(10, 2, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    lift_duration_s: Mapped[float] = mapped_column(
        Numeric(10, 3, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    lift_vertical_m: Mapped[float] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    avg_descent_speed_mps: Mapped[float] = mapped_column(
        Numeric(7, 4, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    total_duration_s: Mapped[float] = mapped_column(
        Numeric(10, 3, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
    processed_by_version: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    processed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    status: Mapped[RideSessionStatus] = mapped_column(
        SqlEnum(RideSessionStatus, name="ride_session_status"),
        nullable=False,
        server_default=text("'DRAFT'"),
        default=RideSessionStatus.DRAFT,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    resort: Mapped["Resort | None"] = relationship("Resort", lazy="joined")
    actions: Mapped[list["RideSessionAction"]] = relationship(
        "RideSessionAction",
        back_populates="session",
        cascade="all, delete-orphan",
        order_by="RideSessionAction.started_at",
    )
    overrides: Mapped[list["RideSessionOverride"]] = relationship(
        "RideSessionOverride",
        back_populates="session",
        cascade="all, delete-orphan",
        order_by="RideSessionOverride.started_at",
    )
