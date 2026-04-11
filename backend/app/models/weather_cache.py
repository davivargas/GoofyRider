import uuid
from datetime import datetime

from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import String
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column

from app.models.base import Base


class WeatherCache(Base):
    __tablename__ = "weather_cache"
    __table_args__ = (
        UniqueConstraint("resort_id", name="uq_weather_cache_resort_id"),
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
        index=True,
    )
    observed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    temp_c: Mapped[float | None] = mapped_column(Float, nullable=True)
    wind_kph: Mapped[float | None] = mapped_column(Float, nullable=True)
    snowfall_cm_24h: Mapped[float | None] = mapped_column(Float, nullable=True)
    conditions_text: Mapped[str | None] = mapped_column(String(120), nullable=True)
    today_high_c: Mapped[float | None] = mapped_column(Float, nullable=True)
    today_low_c: Mapped[float | None] = mapped_column(Float, nullable=True)
    snowfall_next_24h_cm: Mapped[float | None] = mapped_column(Float, nullable=True)
    weather_code_text: Mapped[str | None] = mapped_column(String(120), nullable=True)
    fetched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
