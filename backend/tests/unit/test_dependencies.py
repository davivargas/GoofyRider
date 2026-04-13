from types import SimpleNamespace

from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
import pytest

import app.core.dependencies as dependencies
from app.services.exceptions import AuthenticationError


class FakeAuthService:
    def __init__(
        self,
        user: object | None = None,
        error: AuthenticationError | None = None,
    ) -> None:
        self._user = user
        self._error = error

    def get_user_from_access_token(self, _token: str) -> object:
        if self._error is not None:
            raise self._error
        assert self._user is not None
        return self._user


def _auth_credentials(token: str = "token") -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


def test_get_current_user_requires_auth_header() -> None:
    with pytest.raises(HTTPException) as exc_info:
        dependencies.get_current_user(credentials=None, auth_service=FakeAuthService(user=object()))

    assert exc_info.value.status_code == 401
    assert exc_info.value.detail == "Not authenticated."
    assert exc_info.value.headers == {"WWW-Authenticate": "Bearer"}


def test_get_current_user_rejects_invalid_token() -> None:
    auth_service = FakeAuthService(error=AuthenticationError("Invalid token."))

    with pytest.raises(HTTPException) as exc_info:
        dependencies.get_current_user(credentials=_auth_credentials(), auth_service=auth_service)

    assert exc_info.value.status_code == 401
    assert exc_info.value.detail == "Invalid token."


def test_get_current_user_returns_user_when_token_is_valid() -> None:
    user = SimpleNamespace(email="qa@example.com")
    resolved_user = dependencies.get_current_user(
        credentials=_auth_credentials(),
        auth_service=FakeAuthService(user=user),
    )

    assert resolved_user is user
