import json
from pathlib import Path

import pytest

from app.services.exceptions import ValidationError
from app.services.ski_api_resort_source import SkiApiResortSource
from app.services.ski_api_resort_source import map_ski_api_resort
from app.services.ski_api_resort_source import map_ski_api_resorts_page

FIXTURE_PATH = Path(__file__).resolve().parent.parent / "fixtures" / "ski_api_resorts_page.json"


def test_map_ski_api_resort_normalizes_country_and_region_codes() -> None:
    payload = _load_fixture_payload()

    resort = map_ski_api_resort(payload["data"][0])

    assert resort.external_id == "whistler-blackcomb"
    assert resort.country == "Canada"
    assert resort.region == "British Columbia"
    assert resort.latitude == pytest.approx(50.10693)
    assert resort.longitude == pytest.approx(-122.922073)


def test_map_ski_api_resorts_page_reads_fixture_payload() -> None:
    payload = _load_fixture_payload()

    resorts = map_ski_api_resorts_page(payload)

    assert len(resorts) == 2
    assert resorts[1].country == "United States"
    assert resorts[1].region == "Colorado"


def test_ski_api_resort_source_fetches_paginated_results() -> None:
    requested_pages: list[int] = []
    second_page_payload = {
        "page": 2,
        "per_page": 1,
        "next_page": None,
        "total": 2,
        "total_pages": 2,
        "data": [
            {
                "slug": "sun-peaks",
                "name": "Sun Peaks",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 50.8849, "longitude": -119.8838},
            }
        ],
    }

    def page_fetcher(page: int, _page_size: int) -> dict[str, object]:
        requested_pages.append(page)
        if page == 1:
            return {
                "page": 1,
                "per_page": 1,
                "next_page": 2,
                "total": 2,
                "total_pages": 2,
                "data": [_load_fixture_payload()["data"][0]],
            }
        return second_page_payload

    source = SkiApiResortSource(
        base_url="https://api.skiapi.com/v1",
        api_key=None,
        api_host=None,
        page_size=1,
        timeout_seconds=10,
        page_fetcher=page_fetcher,
    )

    resorts = source.fetch_resorts()

    assert requested_pages == [1, 2]
    assert [resort.external_id for resort in resorts] == [
        "whistler-blackcomb",
        "sun-peaks",
    ]


def test_map_ski_api_resorts_page_rejects_invalid_payload() -> None:
    with pytest.raises(ValidationError, match="data list"):
        map_ski_api_resorts_page({"data": "not-a-list"})


def _load_fixture_payload() -> dict[str, object]:
    with FIXTURE_PATH.open("r", encoding="utf-8") as fixture_file:
        return json.load(fixture_file)
