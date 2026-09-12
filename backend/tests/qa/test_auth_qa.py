from fastapi.testclient import TestClient

from app.core.security import create_access_token

INVALID_REFRESH = "Invalid or expired refresh token."


def test_auth_register_login_refresh_me_logout_flow(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()

    login_response = client.post(
        "/v1/auth/login",
        json={
            "email": user["email"],
            "password": user["password"],
            "device_label": "QA Phone / Android 15",
        },
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
    assert refreshed["refresh_token"] != login_data["refresh_token"]

    stale = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": login_data["refresh_token"]},
    )
    assert stale.status_code == 401
    assert stale.json()["detail"] == INVALID_REFRESH

    # Reuse of the rotated token revoked the family, so the newest token is dead too.
    after_reuse = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": refreshed["refresh_token"]},
    )
    assert after_reuse.status_code == 401


def test_auth_logout_revokes_refresh_token(client: TestClient, register_user) -> None:
    user = register_user()

    logout_response = client.post(
        "/v1/auth/logout",
        json={"refresh_token": user["refresh_token"]},
    )
    assert logout_response.status_code == 204

    refresh_response = client.post(
        "/v1/auth/refresh",
        json={"refresh_token": user["refresh_token"]},
    )
    assert refresh_response.status_code == 401
    assert refresh_response.json()["detail"] == INVALID_REFRESH

    again = client.post("/v1/auth/logout", json={"refresh_token": user["refresh_token"]})
    assert again.status_code == 204


def test_auth_register_duplicate_email_conflict(client: TestClient, register_user) -> None:
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


def test_auth_login_invalid_password_returns_401(client: TestClient, register_user) -> None:
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


def test_auth_refresh_rejects_access_token_and_garbage(client: TestClient, register_user) -> None:
    user = register_user()

    for bad in (user["access_token"], "not-a-token"):
        response = client.post("/v1/auth/refresh", json={"refresh_token": bad})
        assert response.status_code == 401
        assert response.json()["detail"] == INVALID_REFRESH


def test_auth_me_rejects_access_token_with_invalid_subject(client: TestClient) -> None:
    invalid_access = create_access_token("not-a-uuid")
    response = client.get(
        "/v1/auth/me",
        headers={"Authorization": f"Bearer {invalid_access}"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid token subject."


def test_auth_device_label_is_optional_and_bounded(client: TestClient, register_user) -> None:
    user = register_user()

    too_long = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"], "device_label": "x" * 81},
    )
    assert too_long.status_code == 422

    ok = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"]},
    )
    assert ok.status_code == 200
