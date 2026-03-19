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
    assert payload["items"][0]["resort"]["id"] == str(resort.id)


def test_sessions_points_batch_accepts_and_returns_richer_fields(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Sun Peaks")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    payload = {
        "points": [
            {
                "t_offset_ms": 0,
                "latitude": 50.878,
                "longitude": -119.885,
                "accuracy_m": 3.0,
                "elapsed_realtime_ns": 123456789,
                "altitude_m": 1780.5,
                "vertical_accuracy_m": 4.5,
                "speed_mps": 8.4,
                "speed_accuracy_mps": 0.7,
                "heading_deg": 74.0,
                "bearing_accuracy_deg": 5.0,
                "provider": "fused",
                "is_mocked": False,
                "quality_class": "good",
                "quality_score": 0.92,
                "quality_reason": "high_confidence",
                "filtered_latitude": 50.8781,
                "filtered_longitude": -119.8851,
                "filtered_altitude_m": 1779.9,
                "fused_speed_mps": 8.2,
                "derived_speed_mps": 8.1,
                "distance_delta_m": 1.4,
                "motion_state": "moving",
            }
        ]
    }

    upload = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json=payload,
        headers=headers,
    )
    assert upload.status_code == 200
    assert upload.json()["inserted_count"] == 1

    points = client.get(f"/v1/sessions/{session_id}/points", headers=headers)
    assert points.status_code == 200
    item = points.json()["items"][0]
    assert item["elapsed_realtime_ns"] == 123456789
    assert item["vertical_accuracy_m"] == 4.5
    assert item["speed_accuracy_mps"] == 0.7
    assert item["bearing_accuracy_deg"] == 5.0
    assert item["provider"] == "fused"
    assert item["is_mocked"] is False
    assert item["quality_class"] == "good"
    assert item["quality_score"] == 0.92
    assert item["quality_reason"] == "high_confidence"
    assert item["filtered_latitude"] == 50.8781
    assert item["filtered_longitude"] == -119.8851
    assert item["filtered_altitude_m"] == 1779.9
    assert item["fused_speed_mps"] == 8.2
    assert item["derived_speed_mps"] == 8.1
    assert item["distance_delta_m"] == 1.4
    assert item["motion_state"] == "moving"


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


def test_sessions_get_detail_and_points_endpoints(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Kicking Horse")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    upload = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={
            "points": [
                {
                    "t_offset_ms": 0,
                    "latitude": 51.3,
                    "longitude": -117.0,
                },
                {
                    "t_offset_ms": 2000,
                    "latitude": 51.301,
                    "longitude": -117.001,
                },
            ]
        },
        headers=headers,
    )
    assert upload.status_code == 200

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers)
    assert detail.status_code == 200
    assert detail.json()["id"] == session_id
    assert detail.json()["resort"]["id"] == str(resort.id)

    points = client.get(f"/v1/sessions/{session_id}/points", headers=headers)
    assert points.status_code == 200
    points_payload = points.json()
    assert points_payload["session_id"] == session_id
    assert len(points_payload["items"]) == 2


def test_sessions_points_batch_preserves_enriched_fields(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Sun Peaks")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    enriched_point = {
        "t_offset_ms": 0,
        "latitude": 50.95,
        "longitude": -118.16,
        "accuracy_m": 3.2,
        "elapsed_realtime_ns": 123456789,
        "altitude_m": 1450.5,
        "vertical_accuracy_m": 4.1,
        "speed_mps": 6.4,
        "speed_accuracy_mps": 0.4,
        "heading_deg": 182.0,
        "bearing_accuracy_deg": 7.5,
        "provider": "gps",
        "is_mocked": False,
        "quality_class": "good",
        "quality_score": 0.91,
        "quality_reason": "stable_fix",
        "filtered_latitude": 50.9501,
        "filtered_longitude": -118.1601,
        "filtered_altitude_m": 1449.8,
        "fused_speed_mps": 6.1,
        "derived_speed_mps": 6.2,
        "distance_delta_m": 4.7,
        "motion_state": "moving",
    }

    upload = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={"points": [enriched_point]},
        headers=headers,
    )
    assert upload.status_code == 200
    assert upload.json()["inserted_count"] == 1

    points = client.get(f"/v1/sessions/{session_id}/points", headers=headers)
    assert points.status_code == 200
    items = points.json()["items"]
    assert len(items) == 1
    item = items[0]
    assert item["elapsed_realtime_ns"] == 123456789
    assert item["vertical_accuracy_m"] == 4.1
    assert item["speed_accuracy_mps"] == 0.4
    assert item["bearing_accuracy_deg"] == 7.5
    assert item["provider"] == "gps"
    assert item["is_mocked"] is False
    assert item["quality_class"] == "good"
    assert item["quality_score"] == 0.91
    assert item["quality_reason"] == "stable_fix"
    assert item["filtered_latitude"] == 50.9501
    assert item["filtered_longitude"] == -118.1601
    assert item["filtered_altitude_m"] == 1449.8
    assert item["fused_speed_mps"] == 6.1
    assert item["derived_speed_mps"] == 6.2
    assert item["distance_delta_m"] == 4.7
    assert item["motion_state"] == "moving"


def test_sessions_points_batch_is_idempotent_on_duplicate_offsets(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Mt. Bachelor")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    payload = {
        "points": [
            {
                "t_offset_ms": 0,
                "latitude": 44.0,
                "longitude": -121.0,
            },
            {
                "t_offset_ms": 1000,
                "latitude": 44.001,
                "longitude": -121.001,
            },
        ]
    }

    first = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json=payload,
        headers=headers,
    )
    assert first.status_code == 200
    assert first.json()["inserted_count"] == 2

    second = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json=payload,
        headers=headers,
    )
    assert second.status_code == 200
    assert second.json()["inserted_count"] == 0


def test_sessions_points_batch_dedupes_offsets_within_single_payload(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Cypress Mountain")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    payload = {
        "points": [
            {
                "t_offset_ms": 0,
                "latitude": 49.3,
                "longitude": -123.2,
            },
            {
                "t_offset_ms": 0,
                "latitude": 49.3005,
                "longitude": -123.2005,
            },
            {
                "t_offset_ms": 1000,
                "latitude": 49.301,
                "longitude": -123.201,
            },
        ]
    }

    response = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json=payload,
        headers=headers,
    )
    assert response.status_code == 200
    assert response.json()["inserted_count"] == 2

    points = client.get(f"/v1/sessions/{session_id}/points", headers=headers)
    assert points.status_code == 200
    items = points.json()["items"]
    assert len(items) == 2
    offsets = {item["t_offset_ms"] for item in items}
    assert offsets == {0, 1000}
