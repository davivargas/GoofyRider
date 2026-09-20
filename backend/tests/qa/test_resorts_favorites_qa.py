from collections.abc import Callable
from datetime import UTC
from datetime import datetime
import uuid

from fastapi.testclient import TestClient
import pytest
from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.resort_field_override_repository import ResortFieldOverrideRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.resort_source_record_repository import ResortSourceRecordRepository
from app.services.exceptions import ValidationError
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_review_service import ResortReviewService
from tests.qa.catalog_helpers import run_fixture_import


def test_resorts_list_filter_and_detail(
    client: TestClient,
    create_resort: Callable[..., Resort],
) -> None:
    whistler = create_resort(
        name="Whistler Blackcomb",
        country="Canada",
        region="British Columbia",
    )
    create_resort(
        name="Vail",
        country="United States",
        region="Colorado",
    )

    all_resorts = client.get("/v1/resorts")
    assert all_resorts.status_code == 200
    all_payload = all_resorts.json()
    assert all_payload["total"] == 2
    assert len(all_payload["items"]) == 2

    filtered = client.get("/v1/resorts", params={"query": "whistler"})
    assert filtered.status_code == 200
    filtered_payload = filtered.json()
    assert filtered_payload["total"] == 1
    assert filtered_payload["items"][0]["name"] == "Whistler Blackcomb"

    by_region = client.get("/v1/resorts", params={"region": "Colorado"})
    assert by_region.status_code == 200
    assert by_region.json()["total"] == 1

    trimmed = client.get(
        "/v1/resorts",
        params={"query": "  whistler  ", "region": "  British Columbia  "},
    )
    assert trimmed.status_code == 200
    assert trimmed.json()["total"] == 1

    detail = client.get(f"/v1/resorts/{whistler.id}")
    assert detail.status_code == 200
    assert detail.json()["id"] == str(whistler.id)


def test_resort_detail_not_found(client: TestClient) -> None:
    missing_id = uuid.uuid4()
    response = client.get(f"/v1/resorts/{missing_id}")
    assert response.status_code == 404
    assert response.json()["detail"] == "Resort not found."


def test_favorites_lifecycle_and_conflicts(
    client: TestClient,
    create_resort: Callable[..., Resort],
    register_user,
) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Sun Peaks")

    add_response = client.post(f"/v1/users/me/favorites/{resort.id}", headers=headers)
    assert add_response.status_code == 201
    assert add_response.json()["id"] == str(resort.id)

    duplicate_response = client.post(f"/v1/users/me/favorites/{resort.id}", headers=headers)
    assert duplicate_response.status_code == 409
    assert duplicate_response.json()["detail"] == "Resort is already in favorites."

    list_response = client.get("/v1/users/me/favorites", headers=headers)
    assert list_response.status_code == 200
    listed = list_response.json()
    assert len(listed) == 1
    assert listed[0]["id"] == str(resort.id)

    remove_response = client.delete(f"/v1/users/me/favorites/{resort.id}", headers=headers)
    assert remove_response.status_code == 204

    list_after_remove = client.get("/v1/users/me/favorites", headers=headers)
    assert list_after_remove.status_code == 200
    assert list_after_remove.json() == []

    remove_missing = client.delete(f"/v1/users/me/favorites/{resort.id}", headers=headers)
    assert remove_missing.status_code == 404
    assert remove_missing.json()["detail"] == "Favorite resort not found."


def test_favorites_endpoints_require_auth(
    client: TestClient,
    create_resort: Callable[..., Resort],
) -> None:
    resort = create_resort(name="Copper Mountain")

    list_response = client.get("/v1/users/me/favorites")
    assert list_response.status_code == 401

    add_response = client.post(f"/v1/users/me/favorites/{resort.id}")
    assert add_response.status_code == 401

    remove_response = client.delete(f"/v1/users/me/favorites/{resort.id}")
    assert remove_response.status_code == 401


def test_resorts_pagination(
    client: TestClient,
    create_resort: Callable[..., Resort],
) -> None:
    create_resort(name="A Basin")
    create_resort(name="Baker")
    create_resort(name="Crested Butte")

    page_one = client.get("/v1/resorts", params={"page": 1, "page_size": 2})
    assert page_one.status_code == 200
    one_payload = page_one.json()
    assert one_payload["page"] == 1
    assert one_payload["page_size"] == 2
    assert one_payload["total"] == 3
    assert len(one_payload["items"]) == 2

    page_two = client.get("/v1/resorts", params={"page": 2, "page_size": 2})
    assert page_two.status_code == 200
    two_payload = page_two.json()
    assert two_payload["page"] == 2
    assert two_payload["total"] == 3
    assert len(two_payload["items"]) == 1


def test_list_resorts_serves_merged_openskidata_rows(client: TestClient, db: Session) -> None:
    run_fixture_import(db)

    response = client.get("/v1/resorts", params={"query": "Grouse", "page_size": 10})

    assert response.status_code == 200
    body = response.json()
    names = sorted(item["name"] for item in body["items"])
    assert names == ["Grouse Mountain", "Grouse Mountain"]
    grouse_ca = next(item for item in body["items"] if item["country"] == "Canada")
    assert grouse_ca["city"] == "North Vancouver"
    assert grouse_ca["elevation_base_m"] == 880 and grouse_ca["elevation_top_m"] == 1250
    assert set(grouse_ca) == {
        "id",
        "name",
        "country",
        "region",
        "city",
        "latitude",
        "longitude",
        "elevation_base_m",
        "elevation_top_m",
        "created_at",
    }


def test_deactivated_resort_is_hidden_from_list_and_returns_404(
    client: TestClient, db: Session
) -> None:
    run_fixture_import(db)
    resort = ResortRepository(db).get_by_name("Cypress Mountain")
    assert resort is not None
    ResortFieldOverrideRepository(db).upsert(resort.id, "is_active", False, note="qa")
    db.commit()
    ResortMergeService(
        ResortRepository(db),
        ResortSourceRecordRepository(db),
        ResortFieldOverrideRepository(db),
        ResortLiftRepository(db),
    ).merge_stale()
    db.commit()

    listed = client.get("/v1/resorts", params={"query": "Cypress"}).json()["items"]
    assert listed == []
    assert client.get(f"/v1/resorts/{resort.id}").status_code == 404


def test_ski_api_only_record_appears_after_operator_creates_it(
    client: TestClient, db: Session
) -> None:
    run_fixture_import(db)
    records = ResortSourceRecordRepository(db)
    records.add(
        ResortSourceRecord(
            source="ski_api",
            external_id="big-white",
            payload={
                "slug": "big-white",
                "name": "Big White",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.72, "longitude": -118.93},
            },
            content_hash="h",
            fetched_at=datetime.now(UTC),
            match_status="pending_review",
        )
    )
    records.commit()
    assert client.get("/v1/resorts", params={"query": "Big White"}).json()["total"] == 0

    lifts = ResortLiftRepository(db)
    service = ResortReviewService(
        resort_repository=ResortRepository(db),
        record_repository=records,
        merge_service=ResortMergeService(
            ResortRepository(db), records, ResortFieldOverrideRepository(db), lifts
        ),
        lift_sync_service=ResortLiftSyncService(records, lifts),
    )
    new_id = service.create("ski_api", "big-white")

    listed = client.get("/v1/resorts", params={"query": "Big White"}).json()
    assert listed["total"] == 1 and listed["items"][0]["id"] == str(new_id)
    assert (
        listed["items"][0]["country"] == "Canada"
        and listed["items"][0]["region"] == "British Columbia"
    )


def test_rejected_record_never_surfaces(client: TestClient, db: Session) -> None:
    run_fixture_import(db)
    records = ResortSourceRecordRepository(db)
    records.add(
        ResortSourceRecord(
            source="ski_api",
            external_id="ghost",
            payload={"slug": "ghost", "name": "Ghost", "country": "CA", "region": "BC"},
            content_hash="h",
            fetched_at=datetime.now(UTC),
            match_status="pending_review",
        )
    )
    records.commit()
    lifts = ResortLiftRepository(db)
    service = ResortReviewService(
        resort_repository=ResortRepository(db),
        record_repository=records,
        merge_service=ResortMergeService(
            ResortRepository(db), records, ResortFieldOverrideRepository(db), lifts
        ),
        lift_sync_service=ResortLiftSyncService(records, lifts),
    )

    service.reject("ski_api", "ghost")

    assert client.get("/v1/resorts", params={"query": "Ghost"}).json()["total"] == 0
    with pytest.raises(ValidationError):
        service.create("ski_api", "ghost")
