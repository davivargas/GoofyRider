from __future__ import annotations

from datetime import datetime
from typing import Any
import uuid

from sqlalchemy import CheckConstraint
from sqlalchemy import DateTime
from sqlalchemy import ForeignKey
from sqlalchemy import Text
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base

OVERRIDABLE_FIELDS = (
    "name",
    "country",
    "country_code",
    "region",
    "region_code",
    "city",
    "latitude",
    "longitude",
    "elevation_base_m",
    "elevation_top_m",
    "is_active",
)
_FIELD_LIST_SQL = ",".join(f"'{field}'" for field in OVERRIDABLE_FIELDS)


class ResortFieldOverride(Base):
    __tablename__ = "resort_field_overrides"
    __table_args__ = (
        UniqueConstraint("resort_id", "field", name="uq_resort_field_overrides_resort_field"),
        CheckConstraint(f"field IN ({_FIELD_LIST_SQL})", name="ck_resort_field_overrides_field"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    resort_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("resorts.id", ondelete="CASCADE"), nullable=False
    )
    field: Mapped[str] = mapped_column(Text, nullable=False)
    value: Mapped[Any] = mapped_column(JSONB, nullable=False)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
