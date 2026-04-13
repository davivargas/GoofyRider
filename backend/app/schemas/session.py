from datetime import UTC
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator
from pydantic import model_validator

from app.models.ride_session import RideSessionStatus
from app.schemas.base import ORMBaseModel
from app.schemas.base import PaginatedResponse
from app.schemas.session_vocabulary import normalize_motion_state
from app.schemas.session_vocabulary import normalize_provider
from app.schemas.session_vocabulary import normalize_quality_class


class SessionCreateRequest(BaseModel):
    resort_id: UUID | None = None
    started_at: datetime | None = None


class SessionPointInput(BaseModel):
    t_offset_ms: int = Field(ge=0)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_m: float | None = Field(default=None, ge=0)
    elapsed_realtime_ns: int | None = Field(default=None, ge=0)
    recorded_at: datetime | None = None
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
    accepted_for_analytics: bool = True

    @property
    def elapsed_offset_ms(self) -> int:
        return self.t_offset_ms

    @field_validator("provider", mode="before")
    @classmethod
    def normalize_provider_value(cls, value: str | None) -> str | None:
        return normalize_provider(value)

    @field_validator("quality_class", mode="before")
    @classmethod
    def normalize_quality_class_value(cls, value: str | None) -> str | None:
        return normalize_quality_class(value)

    @field_validator("motion_state", mode="before")
    @classmethod
    def normalize_motion_state_value(cls, value: str | None) -> str | None:
        return normalize_motion_state(value)


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

    @field_validator("ended_at", mode="before")
    @classmethod
    def ensure_timezone_aware(cls, value: datetime | str | None) -> datetime | str | None:
        if value is None:
            return value
        if isinstance(value, datetime) and value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value

    @model_validator(mode="after")
    def validate_speed_bounds(self) -> "SessionCompleteRequest":
        if (
            self.avg_speed_mps is not None
            and self.max_speed_mps is not None
            and self.avg_speed_mps > self.max_speed_mps
        ):
            raise ValueError("avg_speed_mps must be less than or equal to max_speed_mps")
        return self


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
    recorded_at: datetime
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
    accepted_for_analytics: bool
    created_at: datetime


class SessionPointsListResponse(BaseModel):
    session_id: UUID
    items: list[SessionPointPublic]


class SessionListResponse(PaginatedResponse[RideSessionPublic]):
    pass
