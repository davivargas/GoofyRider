import json
from pathlib import Path
from typing import Any

from app.services.openskidata_mapping import LIFT_TYPE_BY_OPENSKIDATA
from app.services.openskidata_mapping import map_lift
from app.services.openskidata_mapping import map_ski_area

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "openskidata"


def _features(name: str) -> dict[str, dict[str, Any]]:
    payload = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return {f["properties"]["id"]: f for f in payload["features"]}


def test_map_polygon_ski_area_uses_centroid_bbox_places_and_statistics() -> None:
    view = map_ski_area(_features("ski_areas.geojson")["osd-grouse"])

    assert view.source == "openskidata"
    assert view.name == "Grouse Mountain"
    assert view.latitude is not None and abs(view.latitude - 49.382) < 1e-6
    assert view.longitude is not None and abs(view.longitude - (-123.0815)) < 1e-6
    assert view.bbox == (49.372, -123.095, 49.392, -123.068)
    assert view.boundary is not None and view.boundary["type"] == "Polygon"
    assert (view.country, view.country_code) == ("Canada", "CA")
    assert (view.region, view.region_code) == ("British Columbia", "CA-BC")
    assert view.city == "North Vancouver"
    assert (view.elevation_base_m, view.elevation_top_m) == (880, 1250)
    assert view.lift_envelope == (895, 1231)
    assert view.status == "operating" and view.activities == ("downhill",)


def test_map_point_ski_area_has_no_boundary_or_envelope_when_missing() -> None:
    view = map_ski_area(_features("ski_areas.geojson")["osd-seymour"])

    assert (view.latitude, view.longitude) == (49.366, -122.948)
    assert view.boundary is None and view.bbox is None
    assert view.city is None
    assert view.lift_envelope is None
    assert view.status is None


def test_map_ski_area_tolerates_null_statistics_and_name() -> None:
    feature = _features("ski_areas.geojson")["osd-cypress-nordic"]
    feature["properties"]["name"] = None

    view = map_ski_area(feature)

    assert view.name is None
    assert view.elevation_base_m is None and view.elevation_top_m is None
    assert view.activities == ("nordic",)


def test_map_lift_maps_type_track_id_polyline_and_altitudes() -> None:
    lift = map_lift(_features("lifts.geojson")["osd-lift-1002"])

    assert lift is not None
    assert lift.external_id == "osd-lift-1002"
    assert lift.external_track_id == "osm:way:1002"
    assert (lift.lift_type, lift.osm_aerialway) == ("gondola", "cable_car")
    assert lift.polyline == ((49.373, -123.089), (49.380, -123.081))
    assert (lift.base_altitude_m, lift.top_altitude_m) == (290.0, 1100.0)
    assert lift.ski_area_ids == ("osd-grouse",)
    assert lift.status == "operating"


def test_map_lift_returns_none_for_unsupported_type_or_short_geometry() -> None:
    lifts = _features("lifts.geojson")
    assert map_lift(lifts["osd-lift-4001"]) is None  # funicular
    short = dict(lifts["osd-lift-1001"])
    short["geometry"] = {"type": "LineString", "coordinates": [[-123.0, 49.0, 100]]}
    assert map_lift(short) is None


def test_map_lift_multilinestring_and_missing_osm_source() -> None:
    lift_feature = dict(_features("lifts.geojson")["osd-lift-1001"])
    lift_feature["geometry"] = {
        "type": "MultiLineString",
        "coordinates": [[[-123.0, 49.0], [-123.0, 49.01]], [[-123.0, 49.01], [-123.0, 49.02]]],
    }
    lift_feature["properties"] = dict(lift_feature["properties"], sources=[], name=None)

    lift = map_lift(lift_feature)

    assert lift is not None
    assert lift.polyline == ((49.0, -123.0), (49.01, -123.0), (49.02, -123.0))
    assert lift.external_track_id == "openskidata:osd-lift-1001"
    assert lift.name == "Unnamed chair"
    assert lift.base_altitude_m is None and lift.top_altitude_m is None


def test_multi_area_lift_lists_every_ski_area() -> None:
    lift = map_lift(_features("lifts.geojson")["osd-lift-5001"])
    assert lift is not None and lift.ski_area_ids == ("osd-cypress", "osd-seymour")
    assert lift.lift_type == "tbar"


def test_lift_type_table_covers_the_five_catalog_types_only() -> None:
    assert set(LIFT_TYPE_BY_OPENSKIDATA.values()) == {
        "chair",
        "gondola",
        "surface",
        "tbar",
        "magic_carpet",
    }
    assert "funicular" not in LIFT_TYPE_BY_OPENSKIDATA
    assert "railway" not in LIFT_TYPE_BY_OPENSKIDATA
