"""QA coverage for Step 5: the complete endpoint runs the analyzer synchronously.

Builds a synthetic descending trace so the analyzer classifies the samples as a
single `run` action, then asserts the persisted action rows and the new
summary fields come back on the completion response.
"""

from collections.abc import Callable
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.ride_session_action import RideSessionAction


def test_complete_session_runs_analyzer_and_writes_actions(
    client: TestClient,
    db: Session,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Analyzer Integration Resort")

    created = client.post(
        "/v1/sessions",
        json={
            "resort_id": str(resort.id),
            "started_at": "2026-01-01T00:00:00Z",
        },
        headers=headers,
    )
    assert created.status_code == 201
    session_id = created.json()["id"]

    # 200 samples at 1 Hz moving steadily downhill at ~8 m/s. That speed sits
    # cleanly above DESCENT_SPEED_MPS, and a 1 m per sample altitude drop is
    # below RUN_DESCEND_DELTA_M, so the classifier must tag these as `run`.
    points = []
    for index in range(200):
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

    batch = client.post(
        f"/v1/sessions/{session_id}/points:batch",
        json={"points": points},
        headers=headers,
    )
    assert batch.status_code == 200
    assert batch.json()["inserted_count"] == 200

    complete = client.post(
        f"/v1/sessions/{session_id}/complete",
        json={"ended_at": "2026-01-01T00:03:20Z"},
        headers=headers,
    )
    assert complete.status_code == 200
    completed = complete.json()

    assert completed["status"] == "COMPLETED"
    assert completed["processed_by_version"] is not None
    assert completed["processed_at"] is not None

    # Analyzer-owned summary fields must be populated on the response body.
    assert completed["total_duration_s"] > 0
    assert completed["descent_duration_s"] > 0
    assert completed["descent_distance_m"] > 0
    assert completed["descent_vertical_m"] > 0
    assert completed["avg_descent_speed_mps"] > 0
    assert completed["max_speed_mps"] is not None
    assert completed["peak_altitude_m"] is not None
    assert completed["center_lat"] is not None
    assert completed["center_long"] is not None

    action_rows = list(
        db.scalars(
            select(RideSessionAction).where(
                RideSessionAction.session_id == UUID(session_id)
            )
        ).all()
    )
    assert len(action_rows) >= 1
    run_actions = [a for a in action_rows if a.action_type == "run"]
    assert len(run_actions) >= 1
    assert run_actions[0].source == "live_analyzer"
    assert run_actions[0].duration_s > 0
    assert run_actions[0].distance_m > 0
