import uuid

from fastapi import APIRouter
from fastapi import Depends

from app.core.dependencies import get_weather_service
from app.schemas.weather import WeatherCurrentSummary
from app.schemas.weather import WeatherForecastSummary
from app.schemas.weather import ResortWeatherResponse
from app.services.weather_service import WeatherService

router = APIRouter(prefix="/weather", tags=["weather"])


@router.get("/resorts/{resort_id}", response_model=ResortWeatherResponse)
def get_resort_weather(
    resort_id: uuid.UUID,
    weather_service: WeatherService = Depends(get_weather_service),
) -> ResortWeatherResponse:
    weather = weather_service.get_resort_weather(resort_id)
    return ResortWeatherResponse(
        resort_id=weather.resort_id,
        observed_at=weather.observed_at,
        current=WeatherCurrentSummary(
            temp_c=weather.temp_c,
            wind_kph=weather.wind_kph,
            snowfall_cm_24h=weather.snowfall_cm_24h,
            conditions_text=weather.conditions_text,
        ),
        forecast_summary=WeatherForecastSummary(
            today_high_c=weather.today_high_c,
            today_low_c=weather.today_low_c,
            snowfall_next_24h_cm=weather.snowfall_next_24h_cm,
            weather_code_text=weather.weather_code_text,
        ),
    )
