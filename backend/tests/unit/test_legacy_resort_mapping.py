import pytest

from app.services.exceptions import ValidationError
from app.services.legacy_resort_mapping import map_legacy_resort_view


def test_legacy_payload_maps_to_view() -> None:
    view = map_legacy_resort_view(
        {
            "legacy": True,
            "name": "Grouse Mountain",
            "country": "Canada",
            "region": "British Columbia",
            "city": "North Vancouver",
            "latitude": 49.38,
            "longitude": -123.08,
            "elevation_base_m": 880,
            "elevation_top_m": 1250,
        }
    )

    assert view.source == "ski_api"
    assert (view.name, view.country, view.country_code) == ("Grouse Mountain", "Canada", "CA")
    assert (view.region, view.city) == ("British Columbia", "North Vancouver")
    assert (view.latitude, view.longitude) == (49.38, -123.08)
    assert (view.elevation_base_m, view.elevation_top_m) == (880, 1250)
    assert view.boundary is None and view.lift_envelope is None
    assert view.status is None and view.activities == ()


def test_legacy_payload_with_unknown_country_has_no_code() -> None:
    view = map_legacy_resort_view({"legacy": True, "name": "X", "country": "Narnia", "region": "R"})
    assert view.country == "Narnia" and view.country_code is None


def test_non_legacy_payload_is_rejected() -> None:
    with pytest.raises(ValidationError, match="only legacy records remain"):
        map_legacy_resort_view(
            {
                "slug": "whistler-blackcomb",
                "name": "Whistler Blackcomb",
                "country": "CA",
                "region": "BC",
            }
        )
