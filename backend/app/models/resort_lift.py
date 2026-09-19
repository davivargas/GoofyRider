from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING
import uuid

from sqlalchemy import CheckConstraint
from sqlalchemy import DateTime
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


class ResortLift(Base):
    __tablename__ = "resort_lifts"
    __table_args__ = (
        CheckConstraint(
            "lift_type IN ('chair','gondola','surface','tbar','magic_carpet')",
            name="ck_resort_lifts_lift_type",
        ),
        CheckConstraint("source IN ('overpass','openskidata')", name="ck_resort_lifts_source"),
        Index("ix_resort_lifts_resort_id", "resort_id"),
        Index("ix_resort_lifts_external_track_id", "external_track_id"),
        Index(
            "ix_resort_lifts_resort_track_unique",
            "resort_id",
            "external_track_id",
            unique=True,
            postgresql_where=text("external_track_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    resort_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("resorts.id", ondelete="CASCADE"),
        nullable=False,
    )
    name: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    lift_type: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    osm_aerialway: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    polyline: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    base_altitude_m: Mapped[float | None] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=True,
    )
    top_altitude_m: Mapped[float | None] = mapped_column(
        Numeric(8, 2, asdecimal=False),
        nullable=True,
    )
    external_track_id: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    source: Mapped[str] = mapped_column(
        Text, nullable=False, default="overpass", server_default=text("'overpass'")
    )
    status: Mapped[str | None] = mapped_column(Text, nullable=True)
    source_record_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("resort_source_records.id", ondelete="SET NULL"),
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    resort: Mapped[Resort] = relationship("Resort")
