from fastapi.testclient import TestClient


def test_login_is_rate_limited_per_email(client: TestClient, register_user) -> None:
    user = register_user()
    other = register_user()

    for _ in range(5):
        response = client.post(
            "/v1/auth/login",
            json={"email": user["email"], "password": "wrong"},
        )
        assert response.status_code == 401

    limited = client.post(
        "/v1/auth/login",
        json={"email": user["email"], "password": user["password"]},
    )
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert limited.json()["detail"].startswith("Too many requests. Try again in ")

    unaffected = client.post(
        "/v1/auth/login",
        json={"email": other["email"], "password": other["password"]},
    )
    assert unaffected.status_code == 200


def test_register_is_rate_limited_per_ip(client: TestClient) -> None:
    for i in range(5):
        response = client.post(
            "/v1/auth/register",
            json={
                "email": f"burst{i}@example.com",
                "password": "strongpass123",
                "display_name": "Burst",
            },
        )
        assert response.status_code == 201

    limited = client.post(
        "/v1/auth/register",
        json={"email": "burst5@example.com", "password": "strongpass123", "display_name": "Burst"},
    )
    assert limited.status_code == 429


def test_rate_limit_can_be_disabled(client: TestClient, register_user, monkeypatch) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("RATE_LIMIT_ENABLED", "false")
    get_settings.cache_clear()
    user = register_user()

    for _ in range(7):
        response = client.post(
            "/v1/auth/login",
            json={"email": user["email"], "password": "wrong"},
        )
        assert response.status_code == 401
