from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy.exc import IntegrityError

from app.core.security import ARGON2_PREFIX
from app.core.security import hash_password
from app.core.security import hash_password_pbkdf2
from app.models.refresh_token import RefreshToken
from app.models.user import User
import app.services.auth_service as auth_service_module
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
        self.commit_count = 0

    def get_by_email(self, email: str) -> User | None:
        return self.users_by_email.get(email)

    def get_by_id(self, user_id) -> User | None:
        return self.users_by_id.get(user_id)

    def add(self, user: User) -> None:
        self.pending_user = user

    def commit(self) -> None:
        self.commit_count += 1
        if self.commit_error is not None:
            raise self.commit_error
        if self.pending_user is None:
            return
        if self.pending_user.id is None:
            self.pending_user.id = uuid4()
        self.users_by_email[self.pending_user.email] = self.pending_user
        self.users_by_id[self.pending_user.id] = self.pending_user
        self.pending_user = None

    def rollback(self) -> None:
        self.did_rollback = True

    def refresh(self, _instance: object) -> None:
        return None


class FakeRefreshTokenRepository:
    def __init__(self) -> None:
        self.tokens: list[RefreshToken] = []
        self.commit_count = 0

    def add(self, token: RefreshToken) -> None:
        if token.id is None:
            token.id = uuid4()
        self.tokens.append(token)

    def get_by_hash(self, token_hash: str, *, for_update: bool = False) -> RefreshToken | None:
        return next((t for t in self.tokens if t.token_hash == token_hash), None)

    def revoke(self, token: RefreshToken, *, now, replaced_by=None) -> None:
        token.revoked_at = now
        if replaced_by is not None:
            self.add(replaced_by)
            token.replaced_by_id = replaced_by.id

    def revoke_family(self, family_id, *, now) -> int:
        count = 0
        for token in self.tokens:
            if token.family_id == family_id and token.revoked_at is None:
                token.revoked_at = now
                count += 1
        return count

    def delete_expired(self, *, now) -> int:
        return 0

    def commit(self) -> None:
        self.commit_count += 1

    def rollback(self) -> None:
        return None


def _user(email: str = "rider@example.com", password: str = "strong-pass") -> User:
    user = User(email=email, password_hash=hash_password(password), display_name="Rider")
    user.id = uuid4()
    return user


def _service(
    users: FakeUserRepository | None = None,
    tokens: FakeRefreshTokenRepository | None = None,
    now: datetime | None = None,
) -> tuple[AuthService, FakeUserRepository, FakeRefreshTokenRepository]:
    users = users or FakeUserRepository()
    tokens = tokens or FakeRefreshTokenRepository()
    fixed_now = now or datetime(2026, 9, 12, 12, 0, tzinfo=UTC)
    service = AuthService(
        user_repository=users,
        refresh_token_repository=tokens,
        clock=lambda: fixed_now,
    )
    return service, users, tokens


def _seed_user(users: FakeUserRepository, user: User) -> None:
    users.users_by_email[user.email] = user
    users.users_by_id[user.id] = user


def test_register_rejects_duplicate_email() -> None:
    service, users, _ = _service()
    _seed_user(users, _user())

    with pytest.raises(ConflictError, match=r"Email is already registered."):
        service.register(email="rider@example.com", password="strong-pass", display_name="Rider")


def test_register_rolls_back_when_commit_fails() -> None:
    service, users, _ = _service()
    users.commit_error = IntegrityError("INSERT", {}, Exception("unique violation"))

    with pytest.raises(ConflictError, match=r"Email is already registered."):
        service.register(email="new@example.com", password="strong-pass", display_name="Rider")

    assert users.did_rollback is True


def test_register_issues_stored_refresh_token_with_device_label() -> None:
    service, _, tokens = _service()

    pair = service.register(
        email="new@example.com",
        password="strong-pass",
        display_name="Rider",
        device_label="Pixel 8 / Android 15",
    )

    assert pair["token_type"] == "bearer"
    assert len(tokens.tokens) == 1
    stored = tokens.tokens[0]
    assert stored.device_label == "Pixel 8 / Android 15"
    assert stored.token_hash != pair["refresh_token"]
    assert stored.family_expires_at - stored.issued_at == timedelta(days=90)


def test_login_rejects_unknown_email_with_uniform_timing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service, _, _ = _service()
    calls: list[str] = []
    monkeypatch.setattr(
        auth_service_module,
        "verify_password",
        lambda password, stored: calls.append(stored) or False,
    )

    with pytest.raises(AuthenticationError, match=r"Invalid email or password."):
        service.login(email="missing@example.com", password="bad-pass")

    assert len(calls) == 1
    assert calls[0].startswith(ARGON2_PREFIX)


def test_login_rejects_wrong_password() -> None:
    service, users, _ = _service()
    _seed_user(users, _user())

    with pytest.raises(AuthenticationError, match=r"Invalid email or password."):
        service.login(email="rider@example.com", password="wrong")


def test_login_rehashes_legacy_pbkdf2_password() -> None:
    service, users, tokens = _service()
    legacy = User(
        email="old@example.com",
        password_hash=hash_password_pbkdf2("legacy-pass"),
        display_name="Old",
    )
    legacy.id = uuid4()
    _seed_user(users, legacy)

    service.login(email="old@example.com", password="legacy-pass")

    assert legacy.password_hash.startswith(ARGON2_PREFIX)
    assert users.commit_count >= 1
    assert len(tokens.tokens) == 1


def test_refresh_rotates_and_revokes_previous_token() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    first = service.login(email="rider@example.com", password="strong-pass")

    second = service.refresh(first["refresh_token"])

    assert second["refresh_token"] != first["refresh_token"]
    old, new = tokens.tokens
    assert old.revoked_at is not None
    assert old.replaced_by_id == new.id
    assert new.family_id == old.family_id
    assert new.family_expires_at == old.family_expires_at


def test_refresh_reuse_revokes_whole_family() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    first = service.login(email="rider@example.com", password="strong-pass")
    second = service.refresh(first["refresh_token"])

    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(first["refresh_token"])

    assert all(t.revoked_at is not None for t in tokens.tokens)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(second["refresh_token"])


def test_refresh_rejects_unknown_expired_and_family_expired_tokens() -> None:
    now = datetime(2026, 9, 12, 12, 0, tzinfo=UTC)
    service, users, tokens = _service(now=now)
    _seed_user(users, _user())
    pair = service.login(email="rider@example.com", password="strong-pass")
    stored = tokens.tokens[0]

    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh("not-a-token")

    stored.expires_at = now - timedelta(seconds=1)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])

    stored.expires_at = now + timedelta(days=1)
    stored.family_expires_at = now - timedelta(seconds=1)
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])


def test_logout_revokes_token_and_is_idempotent() -> None:
    service, users, tokens = _service()
    _seed_user(users, _user())
    pair = service.login(email="rider@example.com", password="strong-pass")

    service.logout(pair["refresh_token"])
    service.logout(pair["refresh_token"])
    service.logout("unknown")

    assert tokens.tokens[0].revoked_at is not None
    with pytest.raises(AuthenticationError, match=r"Invalid or expired refresh token."):
        service.refresh(pair["refresh_token"])


def test_get_user_from_access_token_rejects_unknown_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service, _, _ = _service()
    monkeypatch.setattr(
        auth_service_module,
        "decode_token",
        lambda _token, expected_token_type=None: {"sub": str(uuid4())},
    )

    with pytest.raises(AuthenticationError, match=r"User not found."):
        service.get_user_from_access_token("access-token")
