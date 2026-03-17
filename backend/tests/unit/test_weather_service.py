from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import pytest

from app.models.resort import Resort
from app.models.weather_cache import WeatherCache
from app.services.exceptions import NotFoundError
from app.services.weather_service import WeatherService
from app.services.weather_service import WeatherSnapshotData


class FakeResortRepository:
    def __init__(self, resort: Resort | None) -> None:
        self._resort = resort

    def get_by_id(self, _resort_id):
        return self._resort


class FakeWeatherCacheRepository:
    def __init__(self, existing: WeatherCache | None = None) -> None:
        self.cache = existing
        self.committed = False

    def get_by_resort_id(self, _resort_id):
        return self.cache

    def add(self, cache: WeatherCache) -> None:
        self.cache = cache

    def commit(self) -> None:
        self.committed = True

    def refresh(self, _instance: object) -> None:
        return None


class FakeWeatherProvider:
    def __init__(self) -> None:
        self.called = 0

    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData:
        self.called += 1
        return WeatherSnapshotData(
            observed_at=datetime.now(UTC),
            temp_c=1.2,
            wind_kph=5.5,
            snowfall_cm_24h=8.0,
            conditions_text="Snow",
            today_high_c=2.0,
            today_low_c=-5.0,
            snowfall_next_24h_cm=10.0,
            weather_code_text="Snow",
        )


def _build_resort() -> Resort:
    resort = Resort(
        name="Test Resort",
        country="Canada",
        region="BC",
        city="Test",
        latitude=50.1,
        longitude=-122.9,
        elevation_base_m=500,
        elevation_top_m=2000,
    )
    resort.id = uuid4()
    return resort


def test_weather_service_uses_cache_when_fresh() -> None:
    resort = _build_resort()
    fresh_cache = WeatherCache(
        resort_id=resort.id,
        observed_at=datetime.now(UTC),
        temp_c=0.0,
        wind_kph=2.0,
        snowfall_cm_24h=4.0,
        conditions_text="Cached",
        today_high_c=1.0,
        today_low_c=-2.0,
        snowfall_next_24h_cm=3.0,
        weather_code_text="Cached",
        fetched_at=datetime.now(UTC) - timedelta(minutes=10),
    )

    provider = FakeWeatherProvider()
    service = WeatherService(
        resort_repository=FakeResortRepository(resort),
        weather_cache_repository=FakeWeatherCacheRepository(existing=fresh_cache),
        weather_provider=provider,
    )

    result = service.get_resort_weather(resort.id)

    assert result.conditions_text == "Cached"
    assert provider.called == 0


def test_weather_service_fetches_when_cache_missing() -> None:
    resort = _build_resort()
    provider = FakeWeatherProvider()
    cache_repo = FakeWeatherCacheRepository()

    service = WeatherService(
        resort_repository=FakeResortRepository(resort),
        weather_cache_repository=cache_repo,
        weather_provider=provider,
    )

    result = service.get_resort_weather(resort.id)

    assert result.resort_id == resort.id
    assert result.conditions_text == "Snow"
    assert provider.called == 1
    assert cache_repo.committed is True


def test_weather_service_missing_resort_raises_not_found() -> None:
    service = WeatherService(
        resort_repository=FakeResortRepository(None),
        weather_cache_repository=FakeWeatherCacheRepository(),
        weather_provider=FakeWeatherProvider(),
    )

    with pytest.raises(NotFoundError, match="Resort not found."):
        service.get_resort_weather(uuid4())
