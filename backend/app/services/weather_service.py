import uuid
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from typing import Protocol

import httpx

from app.models.resort import Resort
from app.models.weather_cache import WeatherCache
from app.services.exceptions import NotFoundError
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError

CACHE_TTL_MINUTES = 60


@dataclass(frozen=True)
class WeatherSnapshotData:
    observed_at: datetime
    temp_c: float | None
    wind_kph: float | None
    snowfall_cm_24h: float | None
    conditions_text: str | None
    today_high_c: float | None
    today_low_c: float | None
    snowfall_next_24h_cm: float | None
    weather_code_text: str | None


class ResortRepositoryProtocol(Protocol):
    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        ...


class WeatherCacheRepositoryProtocol(Protocol):
    def get_by_resort_id(self, resort_id: uuid.UUID) -> WeatherCache | None:
        ...

    def add(self, cache: WeatherCache) -> None:
        ...

    def commit(self) -> None:
        ...

    def refresh(self, instance: object) -> None:
        ...


class WeatherProviderProtocol(Protocol):
    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData:
        ...


class OpenMeteoWeatherProvider:
    BASE_URL = "https://api.open-meteo.com/v1/forecast"

    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData:
        params = {
            "latitude": latitude,
            "longitude": longitude,
            "current": "temperature_2m,wind_speed_10m,weather_code",
            "daily": "temperature_2m_max,temperature_2m_min,snowfall_sum,weather_code",
            "timezone": "UTC",
            "forecast_days": 2,
        }

        with httpx.Client(timeout=10.0) as client:
            response = client.get(self.BASE_URL, params=params)
            response.raise_for_status()
            payload = response.json()

        current = payload.get("current", {})
        daily = payload.get("daily", {})

        observed_raw = current.get("time")
        observed_at = datetime.fromisoformat(observed_raw).replace(tzinfo=UTC)

        temp_c = _to_optional_float(current.get("temperature_2m"))
        wind_kph = _to_optional_float(current.get("wind_speed_10m"))

        snowfall_daily = daily.get("snowfall_sum") or []
        snowfall_today = _to_optional_float(snowfall_daily[0]) if len(snowfall_daily) > 0 else None
        snowfall_next = _to_optional_float(snowfall_daily[1]) if len(snowfall_daily) > 1 else snowfall_today

        weather_codes = daily.get("weather_code") or []
        today_code = int(weather_codes[0]) if len(weather_codes) > 0 else None
        weather_code_text = weather_code_to_text(today_code)

        return WeatherSnapshotData(
            observed_at=observed_at,
            temp_c=temp_c,
            wind_kph=wind_kph,
            snowfall_cm_24h=snowfall_today,
            conditions_text=weather_code_to_text(current.get("weather_code")),
            today_high_c=_to_optional_float((daily.get("temperature_2m_max") or [None])[0]),
            today_low_c=_to_optional_float((daily.get("temperature_2m_min") or [None])[0]),
            snowfall_next_24h_cm=snowfall_next,
            weather_code_text=weather_code_text,
        )


class WeatherService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        weather_cache_repository: WeatherCacheRepositoryProtocol,
        weather_provider: WeatherProviderProtocol,
    ) -> None:
        self._resort_repository = resort_repository
        self._weather_cache_repository = weather_cache_repository
        self._weather_provider = weather_provider

    def get_resort_weather(self, resort_id: uuid.UUID) -> WeatherCache:
        resort = self._resort_repository.get_by_id(resort_id)
        if resort is None:
            raise NotFoundError("Resort not found.")

        if resort.latitude is None or resort.longitude is None:
            raise ValidationError("Resort coordinates are required for weather lookup.")

        cached = self._weather_cache_repository.get_by_resort_id(resort_id)
        now = datetime.now(UTC)
        if cached is not None and now - cached.fetched_at <= timedelta(minutes=CACHE_TTL_MINUTES):
            return cached

        try:
            snapshot = self._weather_provider.fetch(
                latitude=resort.latitude,
                longitude=resort.longitude,
            )
        except (httpx.HTTPError, ValueError) as exc:
            if cached is not None:
                return cached
            raise ServiceUnavailableError("Weather provider unavailable.") from exc

        if cached is None:
            cached = WeatherCache(
                resort_id=resort_id,
                observed_at=snapshot.observed_at,
                temp_c=snapshot.temp_c,
                wind_kph=snapshot.wind_kph,
                snowfall_cm_24h=snapshot.snowfall_cm_24h,
                conditions_text=snapshot.conditions_text,
                today_high_c=snapshot.today_high_c,
                today_low_c=snapshot.today_low_c,
                snowfall_next_24h_cm=snapshot.snowfall_next_24h_cm,
                weather_code_text=snapshot.weather_code_text,
                fetched_at=now,
            )
            self._weather_cache_repository.add(cached)
        else:
            cached.observed_at = snapshot.observed_at
            cached.temp_c = snapshot.temp_c
            cached.wind_kph = snapshot.wind_kph
            cached.snowfall_cm_24h = snapshot.snowfall_cm_24h
            cached.conditions_text = snapshot.conditions_text
            cached.today_high_c = snapshot.today_high_c
            cached.today_low_c = snapshot.today_low_c
            cached.snowfall_next_24h_cm = snapshot.snowfall_next_24h_cm
            cached.weather_code_text = snapshot.weather_code_text
            cached.fetched_at = now

        self._weather_cache_repository.commit()
        self._weather_cache_repository.refresh(cached)
        return cached


def _to_optional_float(value: object) -> float | None:
    if value is None:
        return None
    return float(value)


def weather_code_to_text(raw_code: object) -> str | None:
    if raw_code is None:
        return None

    code = int(raw_code)
    if code == 0:
        return "Clear"
    if code in {1, 2, 3}:
        return "Partly cloudy"
    if code in {45, 48}:
        return "Fog"
    if code in {51, 53, 55, 56, 57}:
        return "Drizzle"
    if code in {61, 63, 65, 66, 67, 80, 81, 82}:
        return "Rain"
    if code in {71, 73, 75, 77, 85, 86}:
        return "Snow"
    if code in {95, 96, 99}:
        return "Thunderstorm"
    return "Mixed"
