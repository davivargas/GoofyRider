from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import logging
from typing import TypedDict
import uuid

from pydantic import TypeAdapter
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy.exc import IntegrityError

from app.core.config import get_settings
from app.core.security import TOKEN_TYPE_ACCESS
from app.core.security import TokenValidationError
from app.core.security import create_access_token
from app.core.security import decode_token
from app.core.security import dummy_password_hash
from app.core.security import generate_refresh_token
from app.core.security import hash_password
from app.core.security import hash_refresh_token
from app.core.security import needs_rehash
from app.core.security import verify_password
from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.repositories.protocols import RefreshTokenRepositoryProtocol
from app.repositories.protocols import UserRepositoryProtocol
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError

logger = logging.getLogger(__name__)

INVALID_CREDENTIALS = "Invalid email or password."
INVALID_REFRESH_TOKEN = "Invalid or expired refresh token."


class TokenPairPayload(TypedDict):
    access_token: str
    refresh_token: str
    token_type: str


SUBJECT_UUID_ADAPTER = TypeAdapter(uuid.UUID)


def _utc_now() -> datetime:
    return datetime.now(UTC)


class AuthService:
    def __init__(
        self,
        user_repository: UserRepositoryProtocol,
        refresh_token_repository: RefreshTokenRepositoryProtocol,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._user_repository = user_repository
        self._refresh_token_repository = refresh_token_repository
        self._clock = clock or _utc_now

    def register(
        self,
        email: str,
        password: str,
        display_name: str,
        device_label: str | None = None,
    ) -> TokenPairPayload:
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
        logger.info("User registered: %s", user.id)
        return self._issue_token_pair(user, family_id=uuid.uuid4(), device_label=device_label)

    def login(
        self,
        email: str,
        password: str,
        device_label: str | None = None,
    ) -> TokenPairPayload:
        user = self._user_repository.get_by_email(email)
        if user is None:
            # Burn the same hashing cost as a real user so timing does not
            # reveal whether the email exists.
            verify_password(password, dummy_password_hash())
            raise AuthenticationError(INVALID_CREDENTIALS)

        if not verify_password(password, user.password_hash):
            raise AuthenticationError(INVALID_CREDENTIALS)

        if needs_rehash(user.password_hash):
            user.password_hash = hash_password(password)
            self._user_repository.commit()

        return self._issue_token_pair(user, family_id=uuid.uuid4(), device_label=device_label)

    def refresh(self, refresh_token: str, device_label: str | None = None) -> TokenPairPayload:
        now = self._clock()
        token = self._refresh_token_repository.get_by_hash(hash_refresh_token(refresh_token))
        if token is None:
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        if token.revoked_at is not None:
            self._refresh_token_repository.revoke_family(token.family_id, now=now)
            self._refresh_token_repository.commit()
            logger.warning("refresh_token_reuse family=%s user=%s", token.family_id, token.user_id)
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        if token.expires_at <= now or token.family_expires_at <= now:
            raise AuthenticationError(INVALID_REFRESH_TOKEN)

        user = self._user_repository.get_by_id(token.user_id)
        if user is None:
            raise AuthenticationError("User not found.")

        wire_token, token_hash = generate_refresh_token()
        successor = RefreshToken(
            user_id=user.id,
            token_hash=token_hash,
            family_id=token.family_id,
            device_label=device_label or token.device_label,
            issued_at=now,
            expires_at=now + timedelta(days=get_settings().refresh_token_expire_days),
            family_expires_at=token.family_expires_at,
        )
        token.last_used_at = now
        self._refresh_token_repository.revoke(token, now=now, replaced_by=successor)
        self._refresh_token_repository.commit()

        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": wire_token,
            "token_type": "bearer",
        }

    def logout(self, refresh_token: str) -> None:
        token = self._refresh_token_repository.get_by_hash(hash_refresh_token(refresh_token))
        if token is None or token.revoked_at is not None:
            return
        self._refresh_token_repository.revoke(token, now=self._clock())
        self._refresh_token_repository.commit()

    def get_user_from_access_token(self, access_token: str) -> User:
        try:
            payload = decode_token(access_token, expected_token_type=TOKEN_TYPE_ACCESS)
        except TokenValidationError as exc:
            raise AuthenticationError(str(exc)) from exc
        user_id = self._parse_subject(payload.get("sub"))
        user = self._user_repository.get_by_id(user_id)
        if user is None:
            raise AuthenticationError("User not found.")
        return user

    def _parse_subject(self, subject: object) -> uuid.UUID:
        if not isinstance(subject, str) or not subject:
            raise AuthenticationError("Invalid token subject.")

        try:
            return SUBJECT_UUID_ADAPTER.validate_python(subject)
        except PydanticValidationError as exc:
            raise AuthenticationError("Invalid token subject.") from exc

    def _issue_token_pair(
        self,
        user: User,
        *,
        family_id: uuid.UUID,
        device_label: str | None,
    ) -> TokenPairPayload:
        settings = get_settings()
        now = self._clock()
        wire_token, token_hash = generate_refresh_token()
        self._refresh_token_repository.add(
            RefreshToken(
                user_id=user.id,
                token_hash=token_hash,
                family_id=family_id,
                device_label=device_label,
                issued_at=now,
                expires_at=now + timedelta(days=settings.refresh_token_expire_days),
                family_expires_at=now + timedelta(days=settings.refresh_token_family_max_days),
            )
        )
        self._refresh_token_repository.commit()
        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": wire_token,
            "token_type": "bearer",
        }
