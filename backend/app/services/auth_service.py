import uuid
from typing import Protocol
from typing import TypedDict

from sqlalchemy.exc import IntegrityError

from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TOKEN_TYPE_REFRESH
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import create_refresh_token
from app.core.security import decode_token
from app.core.security import hash_password
from app.core.security import verify_password
from app.models.user import User
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError


class TokenPairPayload(TypedDict):
    access_token: str
    refresh_token: str
    token_type: str


class UserRepositoryProtocol(Protocol):
    def get_by_email(self, email: str) -> User | None:
        ...

    def get_by_id(self, user_id: uuid.UUID) -> User | None:
        ...

    def add(self, user: User) -> None:
        ...

    def commit(self) -> None:
        ...

    def rollback(self) -> None:
        ...

    def refresh(self, instance: object) -> None:
        ...


class AuthService:
    def __init__(self, user_repository: UserRepositoryProtocol) -> None:
        self._user_repository = user_repository

    def register(self, email: str, password: str, display_name: str) -> TokenPairPayload:
        existing_user = self._user_repository.get_by_email(email)
        if existing_user is not None:
            raise ConflictError("Email is already registered.")

        user = User(
            email=email,
            password_hash=hash_password(password),
            display_name=display_name,
        )
        self._user_repository.add(user)

        try:
            self._user_repository.commit()
        except IntegrityError as exc:
            self._user_repository.rollback()
            raise ConflictError("Email is already registered.") from exc

        self._user_repository.refresh(user)
        return self._issue_token_pair(user.id)

    def login(self, email: str, password: str) -> TokenPairPayload:
        user = self._user_repository.get_by_email(email)
        if user is None or not verify_password(password, user.password_hash):
            raise AuthenticationError("Invalid email or password.")

        return self._issue_token_pair(user.id)

    def refresh(self, refresh_token: str) -> TokenPairPayload:
        payload = self._decode_token(refresh_token, expected_token_type=TOKEN_TYPE_REFRESH)
        user = self._get_user_from_payload(payload)
        return self._issue_token_pair(user.id)

    def get_user_from_access_token(self, access_token: str) -> User:
        payload = self._decode_token(access_token, expected_token_type=TOKEN_TYPE_ACCESS)
        return self._get_user_from_payload(payload)

    def _decode_token(self, token: str, expected_token_type: str) -> dict[str, object]:
        try:
            return decode_token(token, expected_token_type=expected_token_type)
        except TokenValidationError as exc:
            raise AuthenticationError(str(exc)) from exc

    def _get_user_from_payload(self, payload: dict[str, object]) -> User:
        user_id = self._parse_subject(payload.get("sub"))
        user = self._user_repository.get_by_id(user_id)
        if user is None:
            raise AuthenticationError("User not found.")
        return user

    def _parse_subject(self, subject: object) -> uuid.UUID:
        if not isinstance(subject, str) or not subject:
            raise AuthenticationError("Invalid token subject.")

        try:
            return uuid.UUID(subject)
        except ValueError as exc:
            raise AuthenticationError("Invalid token subject.") from exc

    def _issue_token_pair(self, user_id: uuid.UUID) -> TokenPairPayload:
        subject = str(user_id)
        return {
            "access_token": create_access_token(subject),
            "refresh_token": create_refresh_token(subject),
            "token_type": "bearer",
        }
