from fastapi import APIRouter
from fastapi import Depends
from fastapi import Response
from fastapi import status

from app.core.dependencies import get_auth_service
from app.core.dependencies import get_current_user
from app.core.dependencies import limit_login
from app.core.dependencies import limit_refresh
from app.core.dependencies import limit_register
from app.models.user import User
from app.schemas.auth import LoginRequest
from app.schemas.auth import RefreshTokenRequest
from app.schemas.auth import RegisterRequest
from app.schemas.auth import TokenPair
from app.schemas.user import UserPublic
from app.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post(
    "/register",
    response_model=TokenPair,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_register)],
)
def register(
    payload: RegisterRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    token_pair = auth_service.register(
        email=payload.email,
        password=payload.password,
        display_name=payload.display_name,
        device_label=payload.device_label,
    )
    return TokenPair.model_validate(token_pair)


@router.post("/login", response_model=TokenPair)
def login(
    payload: LoginRequest = Depends(limit_login),
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    token_pair = auth_service.login(
        email=payload.email,
        password=payload.password,
        device_label=payload.device_label,
    )
    return TokenPair.model_validate(token_pair)


@router.post("/refresh", response_model=TokenPair, dependencies=[Depends(limit_refresh)])
def refresh(
    payload: RefreshTokenRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> TokenPair:
    token_pair = auth_service.refresh(payload.refresh_token, device_label=payload.device_label)
    return TokenPair.model_validate(token_pair)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    payload: RefreshTokenRequest,
    auth_service: AuthService = Depends(get_auth_service),
) -> Response:
    auth_service.logout(payload.refresh_token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserPublic)
def get_me(current_user: User = Depends(get_current_user)) -> UserPublic:
    return UserPublic.model_validate(current_user)
