from datetime import UTC
from datetime import datetime
from enum import Enum
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator

from app.models.ride_session import RideSessionStatus
from app.schemas.base import ORMBaseModel
from app.schemas.base import PaginatedResponse
from app.schemas.session_point import SessionPointInput
from app.schemas.session_point import SessionPointPublic as RawSessionPointPublic


class SessionCreateRequest(BaseModel):
    resort_id: UUID | None = None
    started_at: datetime | None = None


class SessionPointsBatchRequest(BaseModel):
    points: list[SessionPointInput] = Field(min_length=1, max_length=5000)


class SessionPointsBatchResponse(BaseModel):
    session_id: UUID
    inserted_count: int = Field(ge=0)


class SessionCompleteRequest(BaseModel):
    ended_at: datetime | None = None

    @field_validator("ended_at", mode="before")
    @classmethod
    def ensure_timezone_aware(cls, value: datetime | str | None) -> datetime | str | None:
        if value is None:
            return value
        if isinstance(value, datetime) and value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value


class SessionCondition(str, Enum):
    PACKED = "PACKED"
    WET = "WET"
    GRANULAR = "GRANULAR"
    GROOMED = "GROOMED"
    POWDER = "POWDER"


class SessionResortSummary(ORMBaseModel):
    id: UUID
    name: str
    country: str
    region: str


class SessionSummary(ORMBaseModel):
    id: UUID
    user_id: UUID
    resort_id: UUID | None
    resort: SessionResortSummary | None = None
    started_at: datetime
    ended_at: datetime | None
    max_speed_mps: float | None
    source: str
    external_identifier: str | None
    conditions: SessionCondition | None
    sport: str
    altitude_offset_m: float | None
    peak_altitude_m: float | None
    center_lat: float | None
    center_long: float | None
    descent_distance_m: float
    descent_duration_s: float
    descent_vertical_m: float
    lift_distance_m: float
    lift_duration_s: float
    lift_vertical_m: float
    avg_descent_speed_mps: float
    total_duration_s: float
    processed_by_version: str | None
    processed_at: datetime | None
    status: RideSessionStatus
    created_at: datetime


class SessionActionRead(ORMBaseModel):
    id: UUID
    session_id: UUID
    action_type: str
    sequence_index: int
    started_at: datetime
    ended_at: datetime
    duration_s: float
    distance_m: float
    avg_speed_mps: float
    min_speed_mps: float | None
    max_speed_mps: float
    vertical_m: float | None
    min_altitude_m: float | None
    max_altitude_m: float | None
    min_lat: float | None
    max_lat: float | None
    min_long: float | None
    max_long: float | None
    top_speed_lat: float | None
    top_speed_long: float | None
    top_speed_alt_m: float | None
    time_of_day: int | None
    external_track_id: str | None
    source: str
    created_at: datetime


class SessionOverrideRead(ORMBaseModel):
    id: UUID
    session_id: UUID
    started_at: datetime
    ended_at: datetime
    motion_state: str
    created_by: str
    created_at: datetime


class SessionDetailResponse(BaseModel):
    session: SessionSummary
    actions: list[SessionActionRead]
    overrides: list[SessionOverrideRead]


class RideSessionPublic(SessionSummary):
    pass


class SessionPointPublic(RawSessionPointPublic):
    @classmethod
    def from_session_point(cls, point: object) -> "SessionPointPublic":
        return cls.model_validate(point)


class SessionPointsListResponse(BaseModel):
    session_id: UUID
    items: list[SessionPointPublic]


class SessionListResponse(PaginatedResponse[RideSessionPublic]):
    pass
