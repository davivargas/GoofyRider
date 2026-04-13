from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class WeatherCurrentSummary(BaseModel):
    temp_c: float | None
    wind_kph: float | None
    snowfall_cm_24h: float | None
    conditions_text: str | None


class WeatherForecastSummary(BaseModel):
    today_high_c: float | None
    today_low_c: float | None
    snowfall_next_24h_cm: float | None
    weather_code_text: str | None


class ResortWeatherResponse(BaseModel):
    resort_id: UUID
    observed_at: datetime
    current: WeatherCurrentSummary
    forecast_summary: WeatherForecastSummary
