import json
from pathlib import Path

import httpx
import pytest

from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.osm_lift_catalog_service import OsmLiftCatalogService

_FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "osm" / "overpass_grouse.json"


def _service(handler) -> OsmLiftCatalogService:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return OsmLiftCatalogService(
        base_url="https://overpass.test/api/interpreter",
        timeout_seconds=5,
        client=client,
        sleep=lambda _: None,
    )


def test_fetch_lifts_posts_an_around_query_and_maps_the_payload() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = request.content.decode()
        seen["agent"] = request.headers.get("user-agent", "")
        return httpx.Response(200, content=_FIXTURE.read_bytes())

    lifts = _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)
    assert seen["url"] == "https://overpass.test/api/interpreter"
    assert (
        "around%3A6000%2C49.38%2C-123.082" in seen["body"]
        or "around:6000,49.38,-123.082" in seen["body"]
    )
    assert seen["agent"].startswith("FallLine/1.0")
    assert {lift.name for lift in lifts} >= {"Screaming Eagle Chair", "Red Skyride"}
    assert not any("Zip Line" in lift.name for lift in lifts)


def test_http_failure_becomes_service_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(504)

    with pytest.raises(ServiceUnavailableError):
        _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)


def test_invalid_json_becomes_validation_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>rate limited</html>")

    with pytest.raises(ValidationError):
        _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)


def test_import_for_resort_requires_coordinates() -> None:
    from unittest.mock import MagicMock

    resort = MagicMock(latitude=None, longitude=None)
    with pytest.raises(ValidationError):
        _service(lambda request: httpx.Response(200, json={"elements": []})).import_for_resort(
            resort, MagicMock(), radius_m=6000
        )


def test_import_for_resort_upserts_mapped_rows() -> None:
    from unittest.mock import MagicMock
    import uuid

    resort = MagicMock(id=uuid.uuid4(), latitude=49.38, longitude=-123.082)
    repository = MagicMock()
    repository.upsert_by_external_track_id.return_value = 8
    service = _service(lambda request: httpx.Response(200, content=_FIXTURE.read_bytes()))

    count = service.import_for_resort(resort, repository, radius_m=6000)

    assert count == 8
    rows = repository.upsert_by_external_track_id.call_args.args[1]
    assert all(row.resort_id == resort.id for row in rows)
    assert {row.osm_aerialway for row in rows} >= {"chair_lift", "cable_car", "magic_carpet"}
    first = json.loads(next(row.polyline for row in rows if row.name == "Peak Chair"))
    assert len(first) >= 2 and len(first[0]) == 2
    repository.commit.assert_called_once()
