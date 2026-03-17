import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Response
from fastapi import status

from app.core.dependencies import get_current_user
from app.core.dependencies import get_favorites_service
from app.models.user import User
from app.schemas.resort import ResortPublic
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.favorites_service import FavoritesService

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me/favorites", response_model=list[ResortPublic])
def list_favorite_resorts(
    current_user: User = Depends(get_current_user),
    favorites_service: FavoritesService = Depends(get_favorites_service),
) -> list[ResortPublic]:
    resorts = favorites_service.list_favorites(current_user.id)
    return [ResortPublic.model_validate(resort) for resort in resorts]


@router.post(
    "/me/favorites/{resort_id}",
    response_model=ResortPublic,
    status_code=status.HTTP_201_CREATED,
)
def add_favorite_resort(
    resort_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    favorites_service: FavoritesService = Depends(get_favorites_service),
) -> ResortPublic:
    try:
        resort = favorites_service.add_favorite(current_user.id, resort_id)
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except ConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc

    return ResortPublic.model_validate(resort)


@router.delete("/me/favorites/{resort_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_favorite_resort(
    resort_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    favorites_service: FavoritesService = Depends(get_favorites_service),
) -> Response:
    try:
        favorites_service.remove_favorite(current_user.id, resort_id)
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc

    return Response(status_code=status.HTTP_204_NO_CONTENT)
