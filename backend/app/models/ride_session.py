import uuid
from datetime import datetime
from enum import Enum

from sqlalchemy import DateTime
from sqlalchemy import Enum as SqlEnum
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Integer
from sqlalchemy import func
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base


class RideSessionStatus(str, Enum):
    DRAFT = "DRAFT"
    COMPLETED = "COMPLETED"
    SYNCED = "SYNCED"


class RideSession(Base):
    __tablename__ = "ride_sessions"
    __table_args__ = (
        Index("ix_ride_sessions_user_id_started_at", "user_id", "started_at"),
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
    duration_s: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True,
    )
    distance_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    max_speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    avg_speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    elevation_gain_m: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True,
    )
    elevation_loss_m: Mapped[int | None] = mapped_column(
        Integer,
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
