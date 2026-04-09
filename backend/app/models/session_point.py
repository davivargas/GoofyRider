import uuid
from datetime import datetime

from sqlalchemy import BigInteger
from sqlalchemy import Boolean
from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Integer
from sqlalchemy import UniqueConstraint
from sqlalchemy import Text
from sqlalchemy import func
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base


class SessionPoint(Base):
    __tablename__ = "session_points"
    __table_args__ = (
        Index("ix_session_points_session_id_t_offset_ms", "session_id", "t_offset_ms"),
        UniqueConstraint(
            "session_id",
            "t_offset_ms",
            name="uq_session_points_session_id_t_offset_ms",
        ),
    )

    id: Mapped[int] = mapped_column(
        BigInteger,
        primary_key=True,
        autoincrement=True,
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("ride_sessions.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    t_offset_ms: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
    )
    latitude: Mapped[float] = mapped_column(
        Float,
        nullable=False,
    )
    longitude: Mapped[float] = mapped_column(
        Float,
        nullable=False,
    )
    accuracy_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    elapsed_realtime_ns: Mapped[int | None] = mapped_column(
        BigInteger,
        nullable=True,
    )
    recorded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    altitude_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    vertical_accuracy_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    speed_accuracy_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    heading_deg: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    bearing_accuracy_deg: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    provider: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    is_mocked: Mapped[bool | None] = mapped_column(
        Boolean,
        nullable=True,
    )
    quality_class: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    quality_score: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    quality_reason: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    filtered_latitude: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    filtered_longitude: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    filtered_altitude_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    fused_speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    derived_speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    distance_delta_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    motion_state: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    accepted_for_analytics: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default=text("true"),
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
