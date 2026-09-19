from app.services.resort_geometry import bbox_of_geometry
from app.services.resort_geometry import centroid_of_geometry
from app.services.resort_geometry import point_in_bbox
from app.services.resort_geometry import point_in_geometry

SQUARE = {
    "type": "Polygon",
    "coordinates": [
        [[-123.1, 49.3], [-123.0, 49.3], [-123.0, 49.4], [-123.1, 49.4], [-123.1, 49.3]]
    ],
}
WITH_HOLE = {
    "type": "Polygon",
    "coordinates": [
        SQUARE["coordinates"][0],
        [[-123.06, 49.34], [-123.04, 49.34], [-123.04, 49.36], [-123.06, 49.36], [-123.06, 49.34]],
    ],
}
MULTI = {
    "type": "MultiPolygon",
    "coordinates": [
        SQUARE["coordinates"],
        [[[-110.0, 45.0], [-109.9, 45.0], [-109.9, 45.1], [-110.0, 45.1], [-110.0, 45.0]]],
    ],
}


def test_bbox_is_min_lat_min_lon_max_lat_max_lon() -> None:
    assert bbox_of_geometry(SQUARE) == (49.3, -123.1, 49.4, -123.0)
    assert bbox_of_geometry(MULTI) == (45.0, -123.1, 49.4, -109.9)
    assert bbox_of_geometry({"type": "Point", "coordinates": [-123.0, 49.0]}) is None


def test_centroid_of_square_is_its_centre() -> None:
    centroid = centroid_of_geometry(SQUARE)
    assert centroid is not None
    assert abs(centroid[0] - 49.35) < 1e-9 and abs(centroid[1] - (-123.05)) < 1e-9


def test_centroid_of_multipolygon_uses_largest_ring() -> None:
    centroid = centroid_of_geometry(MULTI)
    assert centroid is not None and abs(centroid[0] - 49.35) < 1e-9


def test_point_in_geometry_respects_holes_and_multipolygons() -> None:
    assert point_in_geometry(49.32, -123.08, SQUARE)
    assert not point_in_geometry(49.5, -123.08, SQUARE)
    assert not point_in_geometry(49.35, -123.05, WITH_HOLE)
    assert point_in_geometry(45.05, -109.95, MULTI)
    assert not point_in_geometry(49.35, -123.05, {"type": "Point", "coordinates": [0, 0]})


def test_point_in_bbox() -> None:
    assert point_in_bbox(49.35, -123.05, (49.3, -123.1, 49.4, -123.0))
    assert not point_in_bbox(49.45, -123.05, (49.3, -123.1, 49.4, -123.0))
