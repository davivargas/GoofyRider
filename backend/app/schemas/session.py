from datetime import datetime
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator

from app.models.ride_session import RideSessionStatus


class SessionCreateRequest(BaseModel):
    resort_id: UUID | None = None
    started_at: datetime | None = None


class SessionPointInput(BaseModel):
    t_offset_ms: int = Field(ge=0)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_m: float | None = Field(default=None, ge=0)
    altitude_m: float | None = None
    speed_mps: float | None = Field(default=None, ge=0)
    heading_deg: float | None = Field(default=None, ge=0, le=360)


class SessionPointsBatchRequest(BaseModel):
    points: list[SessionPointInput] = Field(min_length=1, max_length=5000)


class SessionPointsBatchResponse(BaseModel):
    session_id: UUID
    inserted_count: int = Field(ge=0)


class SessionCompleteRequest(BaseModel):
    ended_at: datetime | None = None
    duration_s: int | None = Field(default=None, ge=0)
    distance_m: float | None = Field(default=None, ge=0)
    max_speed_mps: float | None = Field(default=None, ge=0)
    avg_speed_mps: float | None = Field(default=None, ge=0)
    elevation_gain_m: int | None = Field(default=None, ge=0)
    elevation_loss_m: int | None = Field(default=None, ge=0)

    @field_validator("avg_speed_mps")
    @classmethod
    def validate_avg_speed(cls, value: float | None, info) -> float | None:
        max_speed = info.data.get("max_speed_mps")
        if value is not None and max_speed is not None and value > max_speed:
            raise ValueError("Average speed cannot be greater than max speed.")
        return value


class SessionResortSummary(BaseModel):
    id: UUID
    name: str
    country: str
    region: str

    model_config = {"from_attributes": True}


class RideSessionPublic(BaseModel):
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

    model_config = {"from_attributes": True}


class SessionPointPublic(BaseModel):
    id: int
    t_offset_ms: int
    latitude: float
    longitude: float
    accuracy_m: float | None
    altitude_m: float | None
    speed_mps: float | None
    heading_deg: float | None
    created_at: datetime

    model_config = {"from_attributes": True}


class SessionPointsListResponse(BaseModel):
    session_id: UUID
    items: list[SessionPointPublic]


class SessionListResponse(BaseModel):
    items: list[RideSessionPublic]
    page: int = Field(ge=1)
    page_size: int = Field(ge=1)
    total: int = Field(ge=0)
