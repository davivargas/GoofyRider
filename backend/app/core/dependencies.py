import uuid
from collections.abc import Generator

from fastapi import Depends
from fastapi import HTTPException
from fastapi import status
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.security import HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TokenValidationError
from app.core.security import decode_token
from app.models.user import User

bearer_scheme = HTTPBearer(auto_error=False)


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None:
        _raise_auth_error("Not authenticated.")

    try:
        payload = decode_token(
            credentials.credentials,
            expected_token_type=TOKEN_TYPE_ACCESS,
        )
    except TokenValidationError as exc:
        _raise_auth_error(str(exc))

    try:
        user_id = uuid.UUID(payload["sub"])
    except ValueError:
        _raise_auth_error("Invalid token subject.")

    user = db.scalar(select(User).where(User.id == user_id))
    if user is None:
        _raise_auth_error("User not found.")

    return user


def _raise_auth_error(detail: str) -> None:
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )
