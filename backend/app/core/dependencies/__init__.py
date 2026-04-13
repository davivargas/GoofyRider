"""Dependency injection factories for FastAPI.

Re-exports every public name so that ``from app.core.dependencies import …``
continues to work after the split into sub-modules.
"""

from app.core.dependencies.auth import bearer_scheme
from app.core.dependencies.auth import get_auth_service
from app.core.dependencies.auth import get_current_user
from app.core.dependencies.auth import get_user_repository
from app.core.dependencies.database import get_db
from app.core.dependencies.resorts import get_favorite_resort_repository
from app.core.dependencies.resorts import get_favorites_service
from app.core.dependencies.resorts import get_resort_repository
from app.core.dependencies.resorts import get_resort_service
from app.core.dependencies.sessions import get_ride_session_repository
from app.core.dependencies.sessions import get_session_point_repository
from app.core.dependencies.sessions import get_session_service
from app.core.dependencies.weather import get_open_meteo_weather_provider
from app.core.dependencies.weather import get_weather_cache_repository
from app.core.dependencies.weather import get_weather_service

__all__ = [
    "bearer_scheme",
    "get_auth_service",
    "get_current_user",
    "get_db",
    "get_favorite_resort_repository",
    "get_favorites_service",
    "get_open_meteo_weather_provider",
    "get_resort_repository",
    "get_resort_service",
    "get_ride_session_repository",
    "get_session_point_repository",
    "get_session_service",
    "get_user_repository",
    "get_weather_cache_repository",
    "get_weather_service",
]
