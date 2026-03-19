from datetime import datetime
from uuid import UUID

from pydantic import Field

from app.schemas.base import ORMBaseModel


class ResortPublic(ORMBaseModel):
    id: UUID
    name: str
    country: str
    region: str
    city: str | None
    latitude: float | None
    longitude: float | None
    elevation_base_m: int | None
    elevation_top_m: int | None
    created_at: datetime


class ResortListResponse(ORMBaseModel):
    items: list[ResortPublic]
    page: int = Field(ge=1)
    page_size: int = Field(ge=1)
    total: int = Field(ge=0)
