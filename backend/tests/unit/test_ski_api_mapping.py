from app.services.ski_api_mapping import map_ski_api_view


def test_legacy_payload_maps_to_view() -> None:
    view = map_ski_api_view(
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


def test_raw_ski_api_payload_maps_to_view() -> None:
    view = map_ski_api_view(
        {
            "slug": "whistler-blackcomb",
            "name": "Whistler Blackcomb",
            "country": "CA",
            "region": "BC",
            "location": {"latitude": 50.10693, "longitude": -122.922073},
            "elevation": {"base_m": 675, "top_m": 2284},
        }
    )

    assert (view.name, view.country, view.country_code) == ("Whistler Blackcomb", "Canada", "CA")
    assert view.region == "British Columbia"
    assert view.city is None
    assert (view.elevation_base_m, view.elevation_top_m) == (675, 2284)


def test_legacy_payload_with_unknown_country_has_no_code() -> None:
    view = map_ski_api_view({"legacy": True, "name": "X", "country": "Narnia", "region": "R"})
    assert view.country == "Narnia" and view.country_code is None
