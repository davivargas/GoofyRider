from __future__ import annotations

from typing import TYPE_CHECKING

from sqlalchemy import BigInteger
from sqlalchemy import Boolean
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Text
from sqlalchemy import text
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.models.base import Base
from app.models.session_point import _motion_state_type
from app.models.session_point import _quality_class_type

if TYPE_CHECKING:
    from app.models.session_point import SessionPoint


class SessionPointAnalytics(Base):
    __tablename__ = "session_point_analytics"

    session_point_id: Mapped[int] = mapped_column(
        BigInteger,
        ForeignKey("session_points.id", ondelete="CASCADE"),
        primary_key=True,
    )
    quality_class: Mapped[str | None] = mapped_column(
        _quality_class_type,
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
        _motion_state_type,
        nullable=True,
    )
    accepted_for_analytics: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default=text("true"),
    )

    session_point: Mapped[SessionPoint] = relationship(
        "SessionPoint",
        back_populates="analytics",
    )
