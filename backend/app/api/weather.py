import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import status

from app.core.dependencies import get_weather_service
from app.schemas.weather import ResortWeatherResponse
from app.services.exceptions import NotFoundError
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.weather_service import WeatherService

router = APIRouter(prefix="/weather", tags=["weather"])


@router.get("/resorts/{resort_id}", response_model=ResortWeatherResponse)
def get_resort_weather(
    resort_id: uuid.UUID,
    weather_service: WeatherService = Depends(get_weather_service),
) -> ResortWeatherResponse:
    try:
        weather = weather_service.get_resort_weather(resort_id)
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except ValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    except ServiceUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc

    return ResortWeatherResponse(
        resort_id=weather.resort_id,
        observed_at=weather.observed_at,
        current={
            "temp_c": weather.temp_c,
            "wind_kph": weather.wind_kph,
            "snowfall_cm_24h": weather.snowfall_cm_24h,
            "conditions_text": weather.conditions_text,
        },
        forecast_summary={
            "today_high_c": weather.today_high_c,
            "today_low_c": weather.today_low_c,
            "snowfall_next_24h_cm": weather.snowfall_next_24h_cm,
            "weather_code_text": weather.weather_code_text,
        },
    )
