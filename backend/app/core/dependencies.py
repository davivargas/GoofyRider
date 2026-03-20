from collections.abc import Generator
from typing import NoReturn

from fastapi import Depends
from fastapi import HTTPException
from fastapi import status
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.security import HTTPBearer
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.models.user import User
from app.repositories.favorite_resort_repository import FavoriteResortRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.repositories.user_repository import UserRepository
from app.repositories.weather_cache_repository import WeatherCacheRepository
from app.services.auth_service import AuthService
from app.services.exceptions import AuthenticationError
from app.services.favorites_service import FavoritesService
from app.services.resort_service import ResortService
from app.services.session_service import SessionService
from app.services.weather_service import OpenMeteoWeatherProvider
from app.services.weather_service import WeatherService

bearer_scheme = HTTPBearer(auto_error=False)


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_user_repository(db: Session = Depends(get_db)) -> UserRepository:
    return UserRepository(db)


def get_resort_repository(db: Session = Depends(get_db)) -> ResortRepository:
    return ResortRepository(db)


def get_favorite_resort_repository(db: Session = Depends(get_db)) -> FavoriteResortRepository:
    return FavoriteResortRepository(db)


def get_ride_session_repository(db: Session = Depends(get_db)) -> RideSessionRepository:
    return RideSessionRepository(db)


def get_session_point_repository(db: Session = Depends(get_db)) -> SessionPointRepository:
    return SessionPointRepository(db)


def get_weather_cache_repository(db: Session = Depends(get_db)) -> WeatherCacheRepository:
    return WeatherCacheRepository(db)


def get_auth_service(
    user_repository: UserRepository = Depends(get_user_repository),
) -> AuthService:
    return AuthService(user_repository=user_repository)


def get_resort_service(
    resort_repository: ResortRepository = Depends(get_resort_repository),
) -> ResortService:
    return ResortService(resort_repository=resort_repository)


def get_favorites_service(
    resort_repository: ResortRepository = Depends(get_resort_repository),
    favorite_resort_repository: FavoriteResortRepository = Depends(get_favorite_resort_repository),
) -> FavoritesService:
    return FavoritesService(
        resort_repository=resort_repository,
        favorite_resort_repository=favorite_resort_repository,
    )


def get_session_service(
    ride_session_repository: RideSessionRepository = Depends(get_ride_session_repository),
    resort_repository: ResortRepository = Depends(get_resort_repository),
    session_point_repository: SessionPointRepository = Depends(get_session_point_repository),
) -> SessionService:
    return SessionService(
        ride_session_repository=ride_session_repository,
        resort_repository=resort_repository,
        session_point_repository=session_point_repository,
    )


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


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    auth_service: AuthService = Depends(get_auth_service),
) -> User:
    if credentials is None:
        _raise_auth_error("Not authenticated.")

    try:
        return auth_service.get_user_from_access_token(credentials.credentials)
    except AuthenticationError as exc:
        _raise_auth_error(str(exc))


def _raise_auth_error(detail: str) -> NoReturn:
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )

