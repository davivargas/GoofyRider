import json
from pathlib import Path

from app.services.osm_lift_mapping import map_overpass_ways

_FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "osm"


def _load(name: str) -> dict[str, object]:
    return json.loads((_FIXTURES / name).read_text(encoding="utf-8"))


def test_grouse_lifts_are_mapped_and_zip_lines_skipped() -> None:
    lifts = {lift.name: lift for lift in map_overpass_ways(_load("overpass_grouse.json"))}
    assert "Screaming Eagle Chair" in lifts
    assert not any("Zip Line" in name for name in lifts)
    assert lifts["Screaming Eagle Chair"].lift_type == "chair"
    assert lifts["Red Skyride"].lift_type == "gondola"
    assert lifts["Red Skyride"].osm_aerialway == "cable_car"
    assert lifts["Magic Carpet"].lift_type == "magic_carpet"
    assert lifts["Side Cut Handle Tow"].lift_type == "surface"
    assert lifts["Peak Chair"].external_track_id.startswith("osm:way:")
    assert len(lifts["Peak Chair"].polyline) >= 2


def test_stations_are_skipped_and_unnamed_lifts_get_a_label() -> None:
    lifts = map_overpass_ways(_load("overpass_cypress.json"))
    assert all(lift.osm_aerialway != "station" for lift in lifts)
    assert any(lift.name == "Unnamed magic_carpet" for lift in lifts)


def test_malformed_elements_are_ignored() -> None:
    payload = {
        "elements": [
            {
                "type": "way",
                "id": 1,
                "tags": {"aerialway": "chair_lift"},
                "geometry": [{"lat": 1.0, "lon": 2.0}],
            },
            {"type": "node", "id": 2},
            {"type": "way", "id": 3},
        ]
    }
    assert map_overpass_ways(payload) == []
