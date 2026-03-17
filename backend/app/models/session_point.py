import uuid
from datetime import datetime

from sqlalchemy import BigInteger
from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Integer
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
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
    altitude_m: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    speed_mps: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    heading_deg: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
