"""Pure mapping from an Overpass `out geom` payload to lift rows (spec section 3.2)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import logging

logger = logging.getLogger(__name__)

_LIFT_TYPE_BY_AERIALWAY = {
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


@dataclass(frozen=True)
class OsmLift:
    name: str
    lift_type: str
    osm_aerialway: str
    polyline: tuple[tuple[float, float], ...]
    external_track_id: str
    base_altitude_m: float | None = None
    top_altitude_m: float | None = None


def map_overpass_ways(payload: Mapping[str, object]) -> list[OsmLift]:
    elements = payload.get("elements")
    if not isinstance(elements, list):
        return []
    lifts: list[OsmLift] = []
    for element in elements:
        if not isinstance(element, dict) or element.get("type") != "way":
            continue
        tags = element.get("tags")
        geometry = element.get("geometry")
        if not isinstance(tags, dict) or not isinstance(geometry, list):
            continue
        aerialway = tags.get("aerialway")
        lift_type = _LIFT_TYPE_BY_AERIALWAY.get(aerialway) if isinstance(aerialway, str) else None
        if lift_type is None or not isinstance(aerialway, str):
            logger.info("Skipping aerialway %r (way %s)", aerialway, element.get("id"))
            continue
        polyline = tuple(
            (float(node["lat"]), float(node["lon"]))
            for node in geometry
            if isinstance(node, dict) and "lat" in node and "lon" in node
        )
        if len(polyline) < 2:
            continue
        name = tags.get("name")
        lifts.append(
            OsmLift(
                name=name if isinstance(name, str) and name.strip() else f"Unnamed {lift_type}",
                lift_type=lift_type,
                osm_aerialway=aerialway,
                polyline=polyline,
                external_track_id=f"osm:way:{element.get('id')}",
            )
        )
    return lifts
