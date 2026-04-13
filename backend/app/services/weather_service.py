from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import logging
from typing import Protocol
import uuid

import httpx
from sqlalchemy.exc import IntegrityError

from app.models.weather_cache import WeatherCache
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import WeatherCacheRepositoryProtocol
from app.schemas.weather_codes import _as_object_sequence
from app.schemas.weather_codes import _to_optional_float
from app.schemas.weather_codes import weather_code_to_text
from app.services.exceptions import NotFoundError
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError

logger = logging.getLogger(__name__)

WEATHER_CACHE_TTL_MINUTES = 60


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


class WeatherProviderProtocol(Protocol):
    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData: ...


class OpenMeteoWeatherProvider:
    BASE_URL = "https://api.open-meteo.com/v1/forecast"

    def __init__(self, client: httpx.Client | None = None) -> None:
        self._client = client

    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData:
        params: dict[str, str | int | float] = {
            "latitude": latitude,
            "longitude": longitude,
            "current": "temperature_2m,wind_speed_10m,weather_code",
            "daily": "temperature_2m_max,temperature_2m_min,snowfall_sum,weather_code",
            "timezone": "UTC",
            "forecast_days": 2,
        }

        if self._client is not None:
            response = self._client.get(self.BASE_URL, params=params)
            response.raise_for_status()
            payload = response.json()
        else:
            with httpx.Client(timeout=10.0) as client:
                response = client.get(self.BASE_URL, params=params)
                response.raise_for_status()
                payload = response.json()

        current = payload.get("current", {})
        daily = payload.get("daily", {})

        observed_raw = current.get("time")
        if not isinstance(observed_raw, str):
            raise ValueError("Weather provider response is missing current.time.")
        observed_text = observed_raw.strip()
        if not observed_text:
            raise ValueError("Weather provider response is missing current.time.")
        observed_at = datetime.fromisoformat(observed_text).replace(tzinfo=UTC)

        temp_c = _to_optional_float(current.get("temperature_2m"))
        wind_kph = _to_optional_float(current.get("wind_speed_10m"))

        snowfall_daily = _as_object_sequence(daily.get("snowfall_sum"))
        snowfall_today = _to_optional_float(snowfall_daily[0]) if len(snowfall_daily) > 0 else None
        snowfall_next = (
            _to_optional_float(snowfall_daily[1]) if len(snowfall_daily) > 1 else snowfall_today
        )

        weather_codes = _as_object_sequence(daily.get("weather_code"))
        today_code_raw = weather_codes[0] if len(weather_codes) > 0 else None
        weather_code_text = weather_code_to_text(today_code_raw)

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
        if cached is not None and now - cached.fetched_at <= timedelta(
            minutes=WEATHER_CACHE_TTL_MINUTES
        ):
            return cached

        try:
            snapshot = self._weather_provider.fetch(
                latitude=resort.latitude,
                longitude=resort.longitude,
            )
        except (httpx.HTTPError, ValueError) as exc:
            if cached is not None:
                logger.warning(
                    "Weather provider unavailable, using cache for resort: %s", resort_id
                )
                return cached
            raise ServiceUnavailableError("Weather provider unavailable.") from exc

        if cached is None:
            cached = self._insert_or_recover_cache(resort_id, snapshot, now)
        else:
            self._apply_snapshot(cached, snapshot, now)
            self._weather_cache_repository.commit()

        self._weather_cache_repository.refresh(cached)
        logger.info("Weather fetched for resort: %s", resort_id)
        return cached

    @staticmethod
    def _apply_snapshot(
        cache: WeatherCache,
        snapshot: WeatherSnapshotData,
        fetched_at: datetime,
    ) -> None:
        cache.observed_at = snapshot.observed_at
        cache.temp_c = snapshot.temp_c
        cache.wind_kph = snapshot.wind_kph
        cache.snowfall_cm_24h = snapshot.snowfall_cm_24h
        cache.conditions_text = snapshot.conditions_text
        cache.today_high_c = snapshot.today_high_c
        cache.today_low_c = snapshot.today_low_c
        cache.snowfall_next_24h_cm = snapshot.snowfall_next_24h_cm
        cache.weather_code_text = snapshot.weather_code_text
        cache.fetched_at = fetched_at

    def _insert_or_recover_cache(
        self,
        resort_id: uuid.UUID,
        snapshot: WeatherSnapshotData,
        now: datetime,
    ) -> WeatherCache:
        cache = WeatherCache(resort_id=resort_id)
        self._apply_snapshot(cache, snapshot, now)
        try:
            self._weather_cache_repository.add(cache)
            self._weather_cache_repository.commit()
        except IntegrityError as exc:
            self._weather_cache_repository.rollback()
            existing = self._weather_cache_repository.get_by_resort_id(resort_id)
            if existing is None:
                raise ServiceUnavailableError("Weather cache conflict: unable to resolve.") from exc
            self._apply_snapshot(existing, snapshot, now)
            self._weather_cache_repository.commit()
            return existing
        return cache
