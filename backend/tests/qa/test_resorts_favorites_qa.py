import uuid
from collections.abc import Callable

from fastapi.testclient import TestClient

from app.models.resort import Resort


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
