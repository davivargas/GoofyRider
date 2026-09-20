"""QA coverage for the session analyze/override/detail API surface.

* `POST /v1/sessions/{id}/analyze`
* `PATCH /v1/sessions/{id}`
* `POST /v1/sessions/{id}/overrides`
* `DELETE /v1/sessions/{id}/overrides/{override_id}`
* `GET  /v1/sessions/{id}` (detail shape: session + actions + overrides)
* `GET  /v1/sessions/{id}/actions`
"""

from collections.abc import Callable
from uuid import UUID
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.ride_session_override import RideSessionOverride


def _downhill_points(count: int = 200) -> list[dict]:
    points: list[dict] = []
    for index in range(count):
        points.append(
            {
                "t_offset_ms": index * 1000,
                "latitude": 50.9500 + index * 0.00007,
                "longitude": -118.1600,
                "altitude_m": 2000.0 - index * 1.0,
                "speed_mps": 8.0,
                "accuracy_m": 3.0,
            }
        )
    return points


def _create_completed_session(
    client: TestClient,
    headers: dict,
    resort: Resort,
    started_at: str = "2026-01-01T00:00:00Z",
    ended_at: str = "2026-01-01T00:03:20Z",
) -> str:
    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id), "started_at": started_at},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    batch = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={"points": _downhill_points()},
        headers=headers,
    )
    assert batch.status_code == 200

    completed = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"ended_at": ended_at},
        headers=headers,
    )
    assert completed.status_code == 200
    return session_id


# --------------------------------------------------------------------------
# POST /sessions/{id}/analyze
# --------------------------------------------------------------------------


def test_analyze_session_reruns_analyzer_and_returns_detail(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Analyze Happy Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.post(
        f"/v1/sessions/{session_id}/analyze",
        json={"include_overrides": True},
        headers=headers,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["session"]["id"] == session_id
    assert body["session"]["status"] == "COMPLETED"
    assert len(body["actions"]) >= 1


def test_analyze_session_unknown_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.post(
        f"/v1/sessions/{uuid4()}/analyze",
        json={"include_overrides": True},
        headers=headers,
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


def test_analyze_session_still_draft_returns_409(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Analyze Draft Resort")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    response = client.post(
        f"/v1/sessions/{session_id}/analyze",
        json={"include_overrides": True},
        headers=headers,
    )
    assert response.status_code == 409


# --------------------------------------------------------------------------
# PATCH /sessions/{id}
# --------------------------------------------------------------------------


def test_patch_session_updates_conditions(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Patch Conditions Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.patch(
        f"/v1/sessions/{session_id}",
        json={"conditions": "PACKED"},
        headers=headers,
    )
    assert response.status_code == 200
    assert response.json()["conditions"] == "PACKED"

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers)
    assert detail.status_code == 200
    assert detail.json()["session"]["conditions"] == "PACKED"


def test_patch_session_unknown_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.patch(
        f"/v1/sessions/{uuid4()}",
        json={"conditions": "PACKED"},
        headers=headers,
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


def test_patch_session_invalid_conditions_returns_422(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Patch Invalid Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.patch(
        f"/v1/sessions/{session_id}",
        json={"conditions": "SLUSH"},
        headers=headers,
    )
    assert response.status_code == 422


def test_patch_session_not_yet_completed_returns_409(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Patch Draft Resort")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    response = client.patch(
        f"/v1/sessions/{session_id}",
        json={"conditions": "PACKED"},
        headers=headers,
    )
    assert response.status_code == 409


# --------------------------------------------------------------------------
# POST /sessions/{id}/overrides
# --------------------------------------------------------------------------


def test_create_override_writes_span_and_returns_detail(
    client: TestClient,
    db: Session,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Override Happy Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["session"]["id"] == session_id
    assert len(body["overrides"]) == 1
    assert body["overrides"][0]["motion_state"] == "ignore"
    assert body["overrides"][0]["created_by"] == "user"

    stored = list(
        db.scalars(
            select(RideSessionOverride).where(RideSessionOverride.session_id == UUID(session_id))
        ).all()
    )
    assert len(stored) == 1
    assert stored[0].created_by == "user"


def test_create_override_rejects_client_created_by_value(
    client: TestClient,
    db: Session,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Override Created By Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
            "created_by": "importer",
        },
        headers=headers,
    )
    assert response.status_code == 200
    stored = list(
        db.scalars(
            select(RideSessionOverride).where(RideSessionOverride.session_id == UUID(session_id))
        ).all()
    )
    assert len(stored) == 1
    assert stored[0].created_by == "user"


def test_create_override_invalid_motion_state_returns_422(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Override Invalid State Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "falling",
        },
        headers=headers,
    )
    assert response.status_code == 422


def test_create_override_unknown_session_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.post(
        f"/v1/sessions/{uuid4()}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


def test_create_override_on_draft_session_returns_409(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Override Draft Resort")

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id)},
        headers=headers,
    )
    session_id = created.json()["id"]

    response = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    assert response.status_code == 409


# --------------------------------------------------------------------------
# DELETE /sessions/{id}/overrides/{override_id}
# --------------------------------------------------------------------------


def test_delete_override_removes_row(
    client: TestClient,
    db: Session,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Delete Override Happy Resort")

    session_id = _create_completed_session(client, headers, resort)

    created = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    assert created.status_code == 200
    override_id = created.json()["overrides"][0]["id"]

    response = client.delete(
        f"/v1/sessions/{session_id}/overrides/{override_id}",
        headers=headers,
    )
    assert response.status_code == 204

    remaining = list(
        db.scalars(
            select(RideSessionOverride).where(RideSessionOverride.session_id == UUID(session_id))
        ).all()
    )
    assert remaining == []


def test_delete_override_unknown_override_id_returns_404(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Delete Override Unknown Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.delete(
        f"/v1/sessions/{session_id}/overrides/{uuid4()}",
        headers=headers,
    )
    assert response.status_code == 404


def test_delete_override_unknown_session_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.delete(
        f"/v1/sessions/{uuid4()}/overrides/{uuid4()}",
        headers=headers,
    )
    assert response.status_code == 404


def test_delete_override_not_owned_by_session_returns_404(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort_a = create_resort(name="Delete Override Session A")
    resort_b = create_resort(name="Delete Override Session B")

    session_a = _create_completed_session(client, headers, resort_a)
    session_b = _create_completed_session(
        client,
        headers,
        resort_b,
        started_at="2026-02-01T00:00:00Z",
        ended_at="2026-02-01T00:03:20Z",
    )

    created = client.post(
        f"/v1/sessions/{session_b}/overrides",
        json={
            "started_at": "2026-02-01T00:00:30Z",
            "ended_at": "2026-02-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    override_id = created.json()["overrides"][0]["id"]

    response = client.delete(
        f"/v1/sessions/{session_a}/overrides/{override_id}",
        headers=headers,
    )
    assert response.status_code == 404


# --------------------------------------------------------------------------
# GET /sessions/{id}
# --------------------------------------------------------------------------


def test_get_session_detail_returns_actions_and_overrides_inline(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Detail Inline Resort")

    session_id = _create_completed_session(client, headers, resort)

    created_override = client.post(
        f"/v1/sessions/{session_id}/overrides",
        json={
            "started_at": "2026-01-01T00:00:30Z",
            "ended_at": "2026-01-01T00:00:50Z",
            "motion_state": "ignore",
        },
        headers=headers,
    )
    assert created_override.status_code == 200

    response = client.get(f"/v1/sessions/{session_id}", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["session"]["id"] == session_id
    assert len(body["actions"]) >= 1
    assert len(body["overrides"]) == 1
    assert body["overrides"][0]["created_by"] == "user"


def test_get_session_detail_unknown_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.get(f"/v1/sessions/{uuid4()}", headers=headers)
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


def test_get_session_detail_cross_user_returns_404(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    owner = register_user()
    attacker = register_user()
    owner_headers = {"Authorization": f"Bearer {owner['access_token']}"}
    attacker_headers = {"Authorization": f"Bearer {attacker['access_token']}"}
    resort = create_resort(name="Cross User Detail Resort")

    session_id = _create_completed_session(client, owner_headers, resort)

    response = client.get(f"/v1/sessions/{session_id}", headers=attacker_headers)
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


# --------------------------------------------------------------------------
# GET /sessions/{id}/actions
# --------------------------------------------------------------------------


def test_list_session_actions_returns_ordered_items(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="List Actions Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.get(f"/v1/sessions/{session_id}/actions", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["session_id"] == session_id
    assert len(body["items"]) >= 1

    started = [item["started_at"] for item in body["items"]]
    assert started == sorted(started)


def test_list_session_actions_unknown_id_returns_404(
    client: TestClient,
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}

    response = client.get(
        f"/v1/sessions/{uuid4()}/actions",
        headers=headers,
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "Session not found."


# --------------------------------------------------------------------------
# POST /sessions/{id}/complete negative — session not in DRAFT.
# (Happy path and shape are covered in test_session_complete_analysis.py.)
# --------------------------------------------------------------------------


def test_complete_session_on_completed_returns_409(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Complete Non Draft Resort")

    session_id = _create_completed_session(client, headers, resort)

    response = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={},
        headers=headers,
    )
    assert response.status_code == 409
    assert response.json()["detail"] == "Only draft sessions can be completed."


def test_session_detail_reports_break_stats(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Break Stats Resort")
    session_id = _create_completed_session(client, headers, resort)

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers)
    assert detail.status_code == 200
    session = detail.json()["session"]
    assert session["break_count"] == 0
    assert session["break_duration_s"] == 0.0
