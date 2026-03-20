from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Response
from fastapi import status

from app.core.dependencies import get_auth_service
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.auth import LoginRequest
from app.schemas.auth import RefreshTokenRequest
from app.schemas.auth import RegisterRequest
from app.schemas.auth import TokenPair
from app.schemas.user import UserPublic
from app.services.auth_service import AuthService
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
def register(
    payload: RegisterRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    try:
        token_pair = auth_service.register(
            email=payload.email,
            password=payload.password,
            display_name=payload.display_name,
        )
    except ConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc

    return TokenPair.model_validate(token_pair)


@router.post("/login", response_model=TokenPair)
def login(
    payload: LoginRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    try:
        token_pair = auth_service.login(email=payload.email, password=payload.password)
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc

    return TokenPair.model_validate(token_pair)


@router.post("/refresh", response_model=TokenPair)
def refresh(
    payload: RefreshTokenRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    try:
        token_pair = auth_service.refresh(payload.refresh_token)
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc

    return TokenPair.model_validate(token_pair)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(_: RefreshTokenRequest) -> Response:
    # Stateless JWT logout: client discards tokens in this phase.
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserPublic)
def get_me(current_user: User = Depends(get_current_user)) -> UserPublic:
    return UserPublic.model_validate(current_user)
