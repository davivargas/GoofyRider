"""Pure mapping from OpenSkiData GeoJSON features to catalog value types (spec 5.2)."""

from __future__ import annotations

from collections.abc import Mapping
import logging
from typing import Any

from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import ExternalLiftRecord
from app.services.catalog_types import SourceResortView
from app.services.exceptions import ValidationError
from app.services.resort_geometry import bbox_of_geometry
from app.services.resort_geometry import centroid_of_geometry

logger = logging.getLogger(__name__)

LIFT_TYPE_BY_OPENSKIDATA: dict[str, str] = {
    "chair_lift": "chair",
    "gondola": "gondola",
    "cable_car": "gondola",
    "mixed_lift": "gondola",
    "drag_lift": "surface",
    "platter": "surface",
    "rope_tow": "surface",
    "j-bar": "surface",
    "t-bar": "tbar",
    "magic_carpet": "magic_carpet",
}
ACTIVE_STATUSES = frozenset({"operating"})


def _props(feature: Mapping[str, Any]) -> dict[str, Any]:
    props = feature.get("properties")
    if not isinstance(props, Mapping):
        raise ValidationError("OpenSkiData feature is missing properties.")
    return dict(props)


def ski_area_external_id(feature: Mapping[str, Any]) -> str:
    external_id = _props(feature).get("id")
    if not isinstance(external_id, str) or not external_id.strip():
        raise ValidationError("OpenSkiData ski area is missing an id.")
    return external_id


def _text(value: object) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return round(value)


def _mapping(value: object) -> dict[str, Any]:
    return dict(value) if isinstance(value, Mapping) else {}


def _place(props: Mapping[str, Any]) -> dict[str, Any]:
    places = props.get("places")
    if isinstance(places, list) and places and isinstance(places[0], Mapping):
        return dict(places[0])
    return {}


def map_ski_area(feature: Mapping[str, Any]) -> SourceResortView:
    props = _props(feature)
    geometry = _mapping(feature.get("geometry"))
    latitude: float | None = None
    longitude: float | None = None
    boundary: dict[str, Any] | None = None
    if geometry.get("type") == "Point":
        coords = geometry.get("coordinates")
        if isinstance(coords, list) and len(coords) >= 2:
            longitude, latitude = float(coords[0]), float(coords[1])
    elif geometry:
        centroid = centroid_of_geometry(geometry)
        if centroid is not None:
            latitude, longitude = centroid
            boundary = geometry

    place = _place(props)
    localized = _mapping(_mapping(place.get("localized")).get("en"))
    statistics = _mapping(props.get("statistics"))
    lifts_stats = _mapping(statistics.get("lifts"))
    env_min = _int(lifts_stats.get("minElevation"))
    env_max = _int(lifts_stats.get("maxElevation"))
    activities = props.get("activities")

    return SourceResortView(
        source=SOURCE_OPENSKIDATA,
        name=_text(props.get("name")),
        latitude=latitude,
        longitude=longitude,
        boundary=boundary,
        bbox=bbox_of_geometry(boundary),
        country=_text(localized.get("country")),
        country_code=_text(place.get("iso3166_1Alpha2")),
        region=_text(localized.get("region")),
        region_code=_text(place.get("iso3166_2")),
        city=_text(localized.get("locality")),
        elevation_base_m=_int(statistics.get("minElevation")),
        elevation_top_m=_int(statistics.get("maxElevation")),
        lift_envelope=(env_min, env_max) if env_min is not None and env_max is not None else None,
        status=_text(props.get("status")),
        activities=tuple(a for a in activities if isinstance(a, str))
        if isinstance(activities, list)
        else (),
    )


def _lines(geometry: object) -> list[list[list[float]]]:
    if not isinstance(geometry, Mapping):
        return []
    coords = geometry.get("coordinates")
    if geometry.get("type") == "LineString" and isinstance(coords, list):
        return [coords]
    if geometry.get("type") == "MultiLineString" and isinstance(coords, list):
        return [line for line in coords if isinstance(line, list)]
    return []


def map_lift(feature: Mapping[str, Any]) -> ExternalLiftRecord | None:
    props = _props(feature)
    external_id = _text(props.get("id"))
    if external_id is None:
        raise ValidationError("OpenSkiData lift is missing an id.")
    osm_type = _text(props.get("liftType"))
    lift_type = LIFT_TYPE_BY_OPENSKIDATA.get(osm_type or "")
    if osm_type is None or lift_type is None:
        logger.info("Skipping lift %s: unsupported liftType %r", external_id, osm_type)
        return None

    positions: list[list[float]] = []
    for line in _lines(feature.get("geometry")):
        for position in line:
            if isinstance(position, list) and len(position) >= 2:
                if positions and positions[-1][:2] == position[:2]:
                    continue
                positions.append(position)
    if len(positions) < 2:
        return None
    polyline = tuple((float(p[1]), float(p[0])) for p in positions)
    first, last = positions[0], positions[-1]
    has_altitudes = len(first) >= 3 and len(last) >= 3
    # A downhill-digitised way puts the summit first; base/top are an envelope, not endpoints.
    base_alt = min(float(first[2]), float(last[2])) if has_altitudes else None
    top_alt = max(float(first[2]), float(last[2])) if has_altitudes else None

    track_id = f"openskidata:{external_id}"
    sources = props.get("sources")
    if isinstance(sources, list):
        for source in sources:
            if isinstance(source, Mapping) and source.get("type") == "openstreetmap":
                osm_id = _text(source.get("id"))
                if osm_id and osm_id.startswith("way/"):
                    track_id = f"osm:way:{osm_id[4:]}"
                    break

    ski_area_ids: list[str] = []
    ski_areas = props.get("skiAreas")
    if isinstance(ski_areas, list):
        for area in ski_areas:
            area_props = _mapping(_mapping(area).get("properties"))
            area_id = _text(area_props.get("id"))
            if area_id:
                ski_area_ids.append(area_id)

    return ExternalLiftRecord(
        external_id=external_id,
        ski_area_ids=tuple(ski_area_ids),
        name=_text(props.get("name")) or f"Unnamed {lift_type}",
        lift_type=lift_type,
        osm_aerialway=osm_type,
        status=_text(props.get("status")),
        polyline=polyline,
        base_altitude_m=base_alt,
        top_altitude_m=top_alt,
        external_track_id=track_id,
    )
