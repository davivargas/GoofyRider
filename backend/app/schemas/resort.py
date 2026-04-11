from datetime import datetime
from uuid import UUID

from app.schemas.base import ORMBaseModel
from app.schemas.base import PaginatedResponse


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


class ResortListResponse(PaginatedResponse[ResortPublic]):
    pass
