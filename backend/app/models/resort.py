from datetime import datetime
import uuid

from sqlalchemy import Boolean
from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import Integer
from sqlalchemy import String
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy import text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base


class Resort(Base):
    __tablename__ = "resorts"
    __table_args__ = (
        UniqueConstraint(
            "name",
            "country",
            "region",
            name="uq_resorts_name_country_region",
        ),
        UniqueConstraint(
            "external_source",
            "external_id",
            name="uq_resorts_external_source_external_id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    name: Mapped[str] = mapped_column(
        String(120),
        nullable=False,
        index=True,
    )
    country: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
    )
    region: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        index=True,
    )
    city: Mapped[str | None] = mapped_column(
        String(100),
        nullable=True,
    )
    latitude: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    longitude: Mapped[float | None] = mapped_column(
        Float,
        nullable=True,
    )
    elevation_base_m: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True,
    )
    elevation_top_m: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True,
    )
    external_source: Mapped[str | None] = mapped_column(
        String(50),
        nullable=True,
    )
    external_id: Mapped[str | None] = mapped_column(
        String(160),
        nullable=True,
    )
    last_source_sync_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default=text("true"),
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
