from fastapi import Depends
from sqlalchemy.orm import Session

from app.core.dependencies.database import get_db
from app.repositories.favorite_resort_repository import FavoriteResortRepository
from app.repositories.resort_repository import ResortRepository
from app.services.favorites_service import FavoritesService
from app.services.resort_service import ResortService


def get_resort_repository(db: Session = Depends(get_db)) -> ResortRepository:
    return ResortRepository(db)


def get_favorite_resort_repository(db: Session = Depends(get_db)) -> FavoriteResortRepository:
    return FavoriteResortRepository(db)


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
