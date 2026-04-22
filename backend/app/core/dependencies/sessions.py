from fastapi import Depends
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.dependencies.database import get_db
from app.core.dependencies.resorts import get_resort_repository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_override_repository import SessionOverrideRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.services.session_analyzer import SessionAnalyzer
from app.services.session_service import SessionService


def get_ride_session_repository(db: Session = Depends(get_db)) -> RideSessionRepository:
    return RideSessionRepository(db)


def get_session_point_repository(db: Session = Depends(get_db)) -> SessionPointRepository:
    return SessionPointRepository(db)


def get_session_override_repository(db: Session = Depends(get_db)) -> SessionOverrideRepository:
    return SessionOverrideRepository(db)


def get_session_analyzer() -> SessionAnalyzer:
    return SessionAnalyzer(analyzer_version=get_settings().session_analyzer_version)


def get_session_service(
    ride_session_repository: RideSessionRepository = Depends(get_ride_session_repository),
    resort_repository: ResortRepository = Depends(get_resort_repository),
    session_point_repository: SessionPointRepository = Depends(get_session_point_repository),
    session_override_repository: SessionOverrideRepository = Depends(
        get_session_override_repository
    ),
    session_analyzer: SessionAnalyzer = Depends(get_session_analyzer),
) -> SessionService:
    return SessionService(
        ride_session_repository=ride_session_repository,
        resort_repository=resort_repository,
        session_point_repository=session_point_repository,
        session_override_repository=session_override_repository,
        session_analyzer=session_analyzer,
    )
