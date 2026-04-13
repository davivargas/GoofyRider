from fastapi import Depends
from sqlalchemy.orm import Session

from app.core.dependencies.database import get_db
from app.core.dependencies.resorts import get_resort_repository
from app.repositories.resort_repository import ResortRepository
from app.repositories.weather_cache_repository import WeatherCacheRepository
from app.services.weather_service import OpenMeteoWeatherProvider
from app.services.weather_service import WeatherService


def get_weather_cache_repository(db: Session = Depends(get_db)) -> WeatherCacheRepository:
    return WeatherCacheRepository(db)


def get_open_meteo_weather_provider() -> OpenMeteoWeatherProvider:
    return OpenMeteoWeatherProvider()


def get_weather_service(
    resort_repository: ResortRepository = Depends(get_resort_repository),
    weather_cache_repository: WeatherCacheRepository = Depends(get_weather_cache_repository),
    weather_provider: OpenMeteoWeatherProvider = Depends(get_open_meteo_weather_provider),
) -> WeatherService:
    return WeatherService(
        resort_repository=resort_repository,
        weather_cache_repository=weather_cache_repository,
        weather_provider=weather_provider,
    )
