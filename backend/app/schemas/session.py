from datetime import datetime
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field

from app.models.ride_session import RideSessionStatus
from app.schemas.base import ORMBaseModel


class SessionCreateRequest(BaseModel):
    resort_id: UUID | None = None
    started_at: datetime | None = None


class SessionPointInput(BaseModel):
    t_offset_ms: int = Field(ge=0)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_m: float | None = Field(default=None, ge=0)
    elapsed_realtime_ns: int | None = Field(default=None, ge=0)
    altitude_m: float | None = None
    vertical_accuracy_m: float | None = Field(default=None, ge=0)
    speed_mps: float | None = Field(default=None, ge=0)
    speed_accuracy_mps: float | None = Field(default=None, ge=0)
    heading_deg: float | None = Field(default=None, ge=0, le=360)
    bearing_accuracy_deg: float | None = Field(default=None, ge=0)
    provider: str | None = None
    is_mocked: bool | None = None
    quality_class: str | None = None
    quality_score: float | None = Field(default=None, ge=0, le=1)
    quality_reason: str | None = None
    filtered_latitude: float | None = Field(default=None, ge=-90, le=90)
    filtered_longitude: float | None = Field(default=None, ge=-180, le=180)
    filtered_altitude_m: float | None = None
    fused_speed_mps: float | None = Field(default=None, ge=0)
    derived_speed_mps: float | None = Field(default=None, ge=0)
    distance_delta_m: float | None = Field(default=None, ge=0)
    motion_state: str | None = None


class SessionPointsBatchRequest(BaseModel):
    points: list[SessionPointInput] = Field(min_length=1, max_length=5000)


class SessionPointsBatchResponse(BaseModel):
    session_id: UUID
    inserted_count: int = Field(ge=0)


class SessionCompleteRequest(BaseModel):
    ended_at: datetime | None = None
    duration_s: int | None = None
    distance_m: float | None = None
    max_speed_mps: float | None = None
    avg_speed_mps: float | None = None
    elevation_gain_m: int | None = None
    elevation_loss_m: int | None = None


class SessionResortSummary(ORMBaseModel):
    id: UUID
    name: str
    country: str
    region: str


class RideSessionPublic(ORMBaseModel):
    id: UUID
    user_id: UUID
    resort_id: UUID | None
    resort: SessionResortSummary | None = None
    started_at: datetime
    ended_at: datetime | None
    duration_s: int | None
    distance_m: float | None
    max_speed_mps: float | None
    avg_speed_mps: float | None
    elevation_gain_m: int | None
    elevation_loss_m: int | None
    status: RideSessionStatus
    created_at: datetime


class SessionPointPublic(ORMBaseModel):
    id: int
    t_offset_ms: int
    latitude: float
    longitude: float
    accuracy_m: float | None
    elapsed_realtime_ns: int | None
    altitude_m: float | None
    vertical_accuracy_m: float | None
    speed_mps: float | None
    speed_accuracy_mps: float | None
    heading_deg: float | None
    bearing_accuracy_deg: float | None
    provider: str | None
    is_mocked: bool | None
    quality_class: str | None
    quality_score: float | None
    quality_reason: str | None
    filtered_latitude: float | None
    filtered_longitude: float | None
    filtered_altitude_m: float | None
    fused_speed_mps: float | None
    derived_speed_mps: float | None
    distance_delta_m: float | None
    motion_state: str | None
    created_at: datetime


class SessionPointsListResponse(BaseModel):
    session_id: UUID
    items: list[SessionPointPublic]


class SessionListResponse(BaseModel):
    items: list[RideSessionPublic]
    page: int = Field(ge=1)
    page_size: int = Field(ge=1)
    total: int = Field(ge=0)
