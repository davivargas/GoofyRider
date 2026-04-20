from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING
import uuid

from sqlalchemy import CheckConstraint
from sqlalchemy import DateTime
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Text
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.models.base import Base

if TYPE_CHECKING:
    from app.models.ride_session import RideSession


class RideSessionOverride(Base):
    __tablename__ = "ride_session_overrides"
    __table_args__ = (
        CheckConstraint(
            "motion_state IN ('run','lift','ignore')",
            name="ck_ride_session_overrides_motion_state",
        ),
        CheckConstraint(
            "created_by IN ('user','importer')",
            name="ck_ride_session_overrides_created_by",
        ),
        Index("ix_ride_session_overrides_session_id_started_at", "session_id", "started_at"),
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
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    ended_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    motion_state: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    created_by: Mapped[str] = mapped_column(
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
        back_populates="overrides",
    )

