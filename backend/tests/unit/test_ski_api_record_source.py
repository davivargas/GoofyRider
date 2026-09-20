from pathlib import Path

import httpx
import pytest

from app.services.catalog_types import SOURCE_SKI_API
from app.services.exceptions import ServiceUnavailableError
from app.services.ski_api_resort_source import SKI_API_EXTERNAL_SOURCE
from app.services.ski_api_resort_source import SkiApiResortSource

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def _source(handler) -> SkiApiResortSource:  # type: ignore[no-untyped-def]
    return SkiApiResortSource(
        base_url="https://ski.test/v1",
        api_key="k",
        api_host="h",
        page_size=25,
        timeout_seconds=5,
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )


def test_ski_api_external_source_matches_catalog_constant() -> None:
    assert SKI_API_EXTERNAL_SOURCE == SOURCE_SKI_API


def test_iter_records_wraps_raw_list_entries() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=(FIXTURES / "ski_api_resorts_page.json").read_bytes())

    records = list(_source(handler).iter_records())

    assert [r.external_id for r in records] == ["whistler-blackcomb", "vail"]
    assert records[0].source == "ski_api" and records[0].snapshot_built_at is None
    assert records[0].payload["name"] == "Whistler Blackcomb"
    assert len(records[0].content_hash) == 64


def test_fetch_detail_returns_data_object_and_maps_errors() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["key"] = request.headers.get("x-rapidapi-key", "")
        if request.url.path.endswith("/resort/grouse-mountain"):
            return httpx.Response(
                200, content=(FIXTURES / "ski_api_resort_detail.json").read_bytes()
            )
        return httpx.Response(500)

    source = _source(handler)
    detail = source.fetch_detail("grouse-mountain")

    assert seen["url"] == "https://ski.test/v1/resort/grouse-mountain" and seen["key"] == "k"
    assert detail["elevation"] == {"base_m": 274, "top_m": 1250}
    with pytest.raises(ServiceUnavailableError):
        source.fetch_detail("missing")


def test_fetch_detail_percent_encodes_the_slug() -> None:
    seen: dict[str, bytes] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["raw_path"] = request.url.raw_path
        return httpx.Response(200, content=b'{"data": {"slug": "x"}}')

    source = _source(handler)
    source.fetch_detail("weird slug/with?stuff")

    assert seen["raw_path"] == b"/v1/resort/weird%20slug%2Fwith%3Fstuff"
