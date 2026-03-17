from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

from fastapi.testclient import TestClient

from app.models.resort import Resort


def test_sessions_lifecycle_create_points_complete_list(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Revelstoke Mountain Resort")

    create_response = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert create_response.status_code == 201
    created_session = create_response.json()
    session_id = created_session["id"]
    assert created_session["status"] == "DRAFT"

    points_response = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={
            "points": [
                {
                    "t_offset_ms": 0,
                    "latitude": 50.95,
                    "longitude": -118.16,
                    "speed_mps": 0.0,
                },
                {
                    "t_offset_ms": 1000,
                    "latitude": 50.951,
                    "longitude": -118.161,
                    "speed_mps": 6.5,
                },
            ]
        },
        headers=headers,
    )
    assert points_response.status_code == 200
    assert points_response.json()["inserted_count"] == 2

    complete_response = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={
            "duration_s": 180,
            "distance_m": 950.0,
            "max_speed_mps": 14.2,
            "avg_speed_mps": 9.7,
            "elevation_gain_m": 40,
            "elevation_loss_m": 300,
        },
        headers=headers,
    )
    assert complete_response.status_code == 200
    completed = complete_response.json()
    assert completed["status"] == "COMPLETED"
    assert completed["duration_s"] == 180

    list_response = client.get("/v1/users/me/sessions", headers=headers)
    assert list_response.status_code == 200
    payload = list_response.json()
    assert payload["total"] == 1
    assert len(payload["items"]) == 1
    assert payload["items"][0]["id"] == session_id


def test_sessions_upload_points_rejects_completed_session(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Mammoth Mountain")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    ).json()
    session_id = created["id"]

    complete_response = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"duration_s": 120, "distance_m": 500.0},
        headers=headers,
    )
    assert complete_response.status_code == 200

    upload_after_complete = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={
            "points": [
                {
                    "t_offset_ms": 0,
                    "latitude": 37.63,
                    "longitude": -119.03,
                }
            ]
        },
        headers=headers,
    )
    assert upload_after_complete.status_code == 409
    assert (
        upload_after_complete.json()["detail"]
        == "Points can only be uploaded to draft sessions."
    )


def test_sessions_complete_rejects_ended_before_started(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Big White")

    started_at = datetime.now(UTC)
    create_response = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id), "started_at": started_at.isoformat()},
        headers=headers,
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["id"]

    ended_at = (started_at - timedelta(minutes=2)).isoformat()
    complete_response = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"ended_at": ended_at},
        headers=headers,
    )
    assert complete_response.status_code == 400
    assert complete_response.json()["detail"] == "ended_at cannot be earlier than started_at."


def test_sessions_create_with_missing_resort_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.post(
        "/v1/sessions",
        json={"resort_id": str(uuid4())},
        headers=headers,
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "Resort not found."


def test_sessions_endpoints_require_auth(client: TestClient) -> None:
    create_response = client.post("/v1/sessions", json={})
    assert create_response.status_code == 401

    list_response = client.get("/v1/users/me/sessions")
    assert list_response.status_code == 401


def test_sessions_cross_user_access_is_blocked(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    owner = register_user()
    attacker = register_user()
    owner_headers = {"Authorization": f"Bearer {owner['access_token']}"}
    attacker_headers = {"Authorization": f"Bearer {attacker['access_token']}"}
    resort = create_resort(name="Lake Louise")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=owner_headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    attacker_upload = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={"points": [{"t_offset_ms": 0, "latitude": 51.42, "longitude": -116.18}]},
        headers=attacker_headers,
    )
    assert attacker_upload.status_code == 404
    assert attacker_upload.json()["detail"] == "Session not found."

    attacker_complete = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"duration_s": 100},
        headers=attacker_headers,
    )
    assert attacker_complete.status_code == 404
    assert attacker_complete.json()["detail"] == "Session not found."


def test_sessions_complete_rejects_already_completed(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Fernie")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    first_complete = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"duration_s": 60},
        headers=headers,
    )
    assert first_complete.status_code == 200

    second_complete = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"duration_s": 60},
        headers=headers,
    )
    assert second_complete.status_code == 409
    assert second_complete.json()["detail"] == "Only draft sessions can be completed."
