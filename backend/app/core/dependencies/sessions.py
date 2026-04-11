from fastapi import Depends
from sqlalchemy.orm import Session

from app.core.dependencies.database import get_db
from app.core.dependencies.resorts import get_resort_repository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.services.session_service import SessionService


def get_ride_session_repository(db: Session = Depends(get_db)) -> RideSessionRepository:
    return RideSessionRepository(db)


def get_session_point_repository(db: Session = Depends(get_db)) -> SessionPointRepository:
    return SessionPointRepository(db)


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
