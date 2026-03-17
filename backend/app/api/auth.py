import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Response
from fastapi import status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.dependencies import get_current_user
from app.core.dependencies import get_db
from app.core.security import TOKEN_TYPE_REFRESH
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import create_refresh_token
from app.core.security import decode_token
from app.core.security import hash_password
from app.core.security import verify_password
from app.models.user import User
from app.schemas.auth import LoginRequest
from app.schemas.auth import RefreshTokenRequest
from app.schemas.auth import RegisterRequest
from app.schemas.auth import TokenPair
from app.schemas.user import UserPublic

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest, db: Session = Depends(get_db)) -> TokenPair:
    existing_user = db.scalar(select(User).where(User.email == payload.email))
    if existing_user is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email is already registered.",
        )

    user = User(
        email=payload.email,
        password_hash=hash_password(payload.password),
        display_name=payload.display_name,
    )
    db.add(user)

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email is already registered.",
        ) from None

    db.refresh(user)
    return _issue_token_pair(user.id)


@router.post("/login", response_model=TokenPair)
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> TokenPair:
    user = db.scalar(select(User).where(User.email == payload.email))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password.",
        )

    return _issue_token_pair(user.id)


@router.post("/refresh", response_model=TokenPair)
def refresh(payload: RefreshTokenRequest, db: Session = Depends(get_db)) -> TokenPair:
    try:
        token_payload = decode_token(
            payload.refresh_token,
            expected_token_type=TOKEN_TYPE_REFRESH,
        )
    except TokenValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc

    try:
        user_id = uuid.UUID(token_payload["sub"])
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token subject.",
        ) from None

    user = db.scalar(select(User).where(User.id == user_id))
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found.",
        )

    return _issue_token_pair(user.id)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(_: RefreshTokenRequest) -> Response:
    # Stateless JWT logout: client discards tokens in this phase.
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserPublic)
def get_me(current_user: User = Depends(get_current_user)) -> UserPublic:
    return UserPublic.model_validate(current_user)


def _issue_token_pair(user_id: uuid.UUID) -> TokenPair:
    subject = str(user_id)
    return TokenPair(
        access_token=create_access_token(subject),
        refresh_token=create_refresh_token(subject),
    )
