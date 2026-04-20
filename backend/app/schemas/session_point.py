from datetime import datetime

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator

from app.schemas.base import ORMBaseModel
from app.schemas.session_vocabulary import normalize_provider


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

    @property
    def elapsed_offset_ms(self) -> int:
        return self.t_offset_ms

    @field_validator("provider", mode="before")
    @classmethod
    def normalize_provider_value(cls, value: str | None) -> str | None:
        return normalize_provider(value)


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
    created_at: datetime

