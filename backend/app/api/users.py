import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import Query
from fastapi import Response
from fastapi import status

from app.core.dependencies import get_current_user
from app.core.dependencies import get_favorites_service
from app.core.dependencies import get_session_service
from app.models.user import User
from app.schemas.resort import ResortPublic
from app.schemas.session import RideSessionPublic
from app.schemas.session import SessionListResponse
from app.services.favorites_service import FavoritesService
from app.services.session_service import SessionService

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
    resort = favorites_service.add_favorite(current_user.id, resort_id)
    return ResortPublic.model_validate(resort)


@router.delete("/me/favorites/{resort_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_favorite_resort(
    resort_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    favorites_service: FavoritesService = Depends(get_favorites_service),
) -> Response:
    favorites_service.remove_favorite(current_user.id, resort_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me/sessions", response_model=SessionListResponse)
def list_user_sessions(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionListResponse:
    sessions, total = session_service.list_user_sessions(
        user_id=current_user.id,
        page=page,
        page_size=page_size,
    )
    return SessionListResponse(
        items=[RideSessionPublic.model_validate(session) for session in sessions],
        page=page,
        page_size=page_size,
        total=total,
    )
