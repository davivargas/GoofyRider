from fastapi.testclient import TestClient

from app.core.security import create_access_token
from app.core.security import create_refresh_token


def test_auth_register_login_refresh_me_flow(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()

    login_response = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"]},
    )
    assert login_response.status_code == 200
    login_data = login_response.json()
    assert login_data["token_type"] == "bearer"

    me_response = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {login_data['access_token']}"},
    )
    assert me_response.status_code == 200
    assert me_response.json()["email"] == user["email"]

    refresh_response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": login_data["refresh_token"]},
    )
    assert refresh_response.status_code == 200
    refreshed = refresh_response.json()
    assert refreshed["token_type"] == "bearer"

    me_after_refresh = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {refreshed['access_token']}"},
    )
    assert me_after_refresh.status_code == 200

    logout_response = client.post(
        "/v1/auth/logout",
        json={"refresh_token": refreshed["refresh_token"]},
    )
    assert logout_response.status_code == 204


def test_auth_register_duplicate_email_conflict(
    client: TestClient,
    register_user,
) -> None:
    first_user = register_user()

    duplicate_response = client.post(
        "/v1/auth/register",
        json={
            "email": first_user["email"],
            "password": "another-strong-pass",
            "display_name": "Duplicate User",
        },
    )
    assert duplicate_response.status_code == 409
    assert duplicate_response.json()["detail"] == "Email is already registered."


def test_auth_login_invalid_password_returns_401(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()

    response = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": "wrong-password"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid email or password."


def test_auth_me_without_token_returns_401(client: TestClient) -> None:
    response = client.get("/v1/auth/me")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_auth_refresh_rejects_access_token(client: TestClient, register_user) -> None:
    user = register_user()

    response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": user["access_token"]},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token type."


def test_auth_refresh_rejects_malformed_token(client: TestClient) -> None:
    response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": "not-a-jwt"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token."


def test_auth_refresh_rejects_unknown_user(client: TestClient) -> None:
    response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": create_refresh_token("a2fa2f93-9fd9-4b7f-8fee-6f85f25fc5ca")},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "User not found."


def test_auth_me_rejects_access_token_with_invalid_subject(client: TestClient) -> None:
    invalid_access = create_access_token("not-a-uuid")
    response = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {invalid_access}"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token subject."
