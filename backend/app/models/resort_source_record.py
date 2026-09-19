from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING
from typing import Any
import uuid

from sqlalchemy import CheckConstraint
from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Index
from sqlalchemy import Text
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.models.base import Base

if TYPE_CHECKING:
    from app.models.resort import Resort

SOURCE_VALUES = ("openskidata", "ski_api")
MATCH_STATUS_VALUES = ("linked", "pending_review", "rejected")
MATCH_METHOD_VALUES = ("primary", "auto", "manual", "legacy")


class ResortSourceRecord(Base):
    __tablename__ = "resort_source_records"
    __table_args__ = (
        UniqueConstraint("source", "external_id", name="uq_resort_source_records_source_ext"),
        CheckConstraint(
            "source IN ('openskidata','ski_api')", name="ck_resort_source_records_source"
        ),
        CheckConstraint(
            "match_status IN ('linked','pending_review','rejected')",
            name="ck_resort_source_records_match_status",
        ),
        CheckConstraint(
            "match_method IS NULL OR match_method IN ('primary','auto','manual','legacy')",
            name="ck_resort_source_records_match_method",
        ),
        Index("ix_resort_source_records_resort_id", "resort_id"),
        Index("ix_resort_source_records_source_status", "source", "match_status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    source: Mapped[str] = mapped_column(Text, nullable=False)
    external_id: Mapped[str] = mapped_column(Text, nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    content_hash: Mapped[str] = mapped_column(Text, nullable=False)
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    snapshot_built_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    missing_since: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    resort_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("resorts.id", ondelete="SET NULL"), nullable=True
    )
    match_status: Mapped[str] = mapped_column(Text, nullable=False)
    match_method: Mapped[str | None] = mapped_column(Text, nullable=True)
    match_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    match_candidates: Mapped[list[dict[str, Any]] | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    resort: Mapped[Resort | None] = relationship("Resort")
