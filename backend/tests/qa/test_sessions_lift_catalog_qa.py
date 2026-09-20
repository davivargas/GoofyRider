from collections.abc import Callable
import json
import uuid

from app.models.resort_lift import ResortLift
from app.models.ride_session_action import RideSessionAction
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from tests.qa.catalog_helpers import run_fixture_import

DEG_LAT_PER_M = 1.0 / 110_540.0


def _climb_points(count: int = 240) -> list[dict]:
    return [
        {
            "t_offset_ms": i * 1000,
            "latitude": 49.4 + 4.0 * i * DEG_LAT_PER_M,
            "longitude": -123.0,
            "altitude_m": 700.0 + 1.5 * i,
            "speed_mps": 4.0,
            "accuracy_m": 3.0,
        }
        for i in range(count)
    ]


def test_completed_session_names_the_lift_it_rode(client, create_resort, register_user, db) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Catalog Resort")
    db.add(
        ResortLift(
            resort_id=resort.id,
            name="Test Chair",
            lift_type="chair",
            osm_aerialway="chair_lift",
            polyline=json.dumps([[49.4, -123.0], [49.4 + 1000 * DEG_LAT_PER_M, -123.0]]),
            external_track_id="osm:way:1",
        )
    )
    db.commit()

    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"},
        headers=headers,
    )
    session_id = created.json()["id"]
    assert (
        client.post(
            f"/v1/sessions/{session_id}/points:batch",
            json={"points": _climb_points()},
            headers=headers,
        ).status_code
        == 200
    )
    assert (
        client.post(
            f"/v1/sessions/{session_id}/complete",
            json={"ended_at": "2026-01-01T00:04:00Z"},
            headers=headers,
        ).status_code
        == 200
    )

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers).json()
    assert [a["action_type"] for a in detail["actions"]] == ["lift"]
    assert "lift_name" not in detail["actions"][0]
    stored = (
        db.query(RideSessionAction)
        .filter(RideSessionAction.session_id == uuid.UUID(session_id))
        .all()
    )
    assert [a.lift_name for a in stored] == ["Test Chair"]
    assert stored[0].external_track_id == "osm:way:1"


def test_session_without_catalog_still_analyzes(client, create_resort, register_user) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Empty Catalog Resort")
    created = client.post(
        "/v1/sessions",
        json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"},
        headers=headers,
    )
    session_id = created.json()["id"]
    assert (
        client.post(
            f"/v1/sessions/{session_id}/points:batch",
            json={"points": _climb_points()},
            headers=headers,
        ).status_code
        == 200
    )
    assert (
        client.post(
            f"/v1/sessions/{session_id}/complete",
            json={"ended_at": "2026-01-01T00:04:00Z"},
            headers=headers,
        ).status_code
        == 200
    )
    detail = client.get(f"/v1/sessions/{session_id}", headers=headers).json()
    assert [a["action_type"] for a in detail["actions"]] == ["lift"]


def test_analysis_anchors_to_openskidata_lifts(
    client, db, register_user: Callable[..., dict[str, str]]
) -> None:
    run_fixture_import(db)
    # "Grouse Mountain" matches two resorts in the fixture (Canada and the
    # United States); get_by_name is not ordering-safe when a name is
    # ambiguous, so pick the Canadian one explicitly.
    resort = next(
        r
        for r in ResortRepository(db).list_all_for_matching()
        if r.name == "Grouse Mountain" and r.country == "Canada"
    )
    lifts = ResortLiftRepository(db).list_by_resort(resort.id)
    assert {lift.source for lift in lifts} == {"openskidata"}
    assert len(lifts) == 3
    skyride = next(lift for lift in lifts if lift.external_track_id == "osm:way:1002")
    assert skyride.base_altitude_m == 290.0 and skyride.top_altitude_m == 1100.0
