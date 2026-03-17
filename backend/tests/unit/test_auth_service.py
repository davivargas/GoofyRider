from uuid import uuid4

import pytest
from sqlalchemy.exc import IntegrityError

import app.services.auth_service as auth_service_module
from app.core.security import hash_password
from app.models.user import User
from app.services.auth_service import AuthService
from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError


class FakeUserRepository:
    def __init__(self) -> None:
        self.users_by_email: dict[str, User] = {}
        self.users_by_id: dict[object, User] = {}
        self.pending_user: User | None = None
        self.commit_error: Exception | None = None
        self.did_rollback = False

    def get_by_email(self, email: str) -> User | None:
        return self.users_by_email.get(email)

    def get_by_id(self, user_id) -> User | None:
        return self.users_by_id.get(user_id)

    def add(self, user: User) -> None:
        self.pending_user = user

    def commit(self) -> None:
        if self.commit_error is not None:
            raise self.commit_error

        assert self.pending_user is not None
        if self.pending_user.id is None:
            self.pending_user.id = uuid4()
        self.users_by_email[self.pending_user.email] = self.pending_user
        self.users_by_id[self.pending_user.id] = self.pending_user

    def rollback(self) -> None:
        self.did_rollback = True

    def refresh(self, _instance: object) -> None:
        return None


def test_register_rejects_duplicate_email() -> None:
    repository = FakeUserRepository()
    existing_user = User(
        email="rider@example.com",
        password_hash=hash_password("strong-pass"),
        display_name="Rider",
    )
    existing_user.id = uuid4()
    repository.users_by_email[existing_user.email] = existing_user

    service = AuthService(user_repository=repository)
    with pytest.raises(ConflictError, match="Email is already registered."):
        service.register(
            email="rider@example.com",
            password="strong-pass",
            display_name="Rider",
        )


def test_register_rolls_back_when_commit_fails() -> None:
    repository = FakeUserRepository()
    repository.commit_error = IntegrityError("INSERT", {}, Exception("unique violation"))
    service = AuthService(user_repository=repository)

    with pytest.raises(ConflictError, match="Email is already registered."):
        service.register(
            email="new@example.com",
            password="strong-pass",
            display_name="Rider",
        )

    assert repository.did_rollback is True


def test_login_rejects_invalid_credentials() -> None:
    repository = FakeUserRepository()
    service = AuthService(user_repository=repository)

    with pytest.raises(AuthenticationError, match="Invalid email or password."):
        service.login(email="missing@example.com", password="bad-pass")


def test_refresh_rejects_invalid_token_subject(monkeypatch: pytest.MonkeyPatch) -> None:
    repository = FakeUserRepository()
    service = AuthService(user_repository=repository)
    monkeypatch.setattr(
        auth_service_module,
        "decode_token",
        lambda _token, expected_token_type=None: {"sub": "not-a-uuid"},
    )

    with pytest.raises(AuthenticationError, match="Invalid token subject."):
        service.refresh("refresh-token")


def test_get_user_from_access_token_rejects_unknown_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = FakeUserRepository()
    service = AuthService(user_repository=repository)
    monkeypatch.setattr(
        auth_service_module,
        "decode_token",
        lambda _token, expected_token_type=None: {"sub": str(uuid4())},
    )

    with pytest.raises(AuthenticationError, match="User not found."):
        service.get_user_from_access_token("access-token")
