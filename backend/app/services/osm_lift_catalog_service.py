"""Fetch resort lift lines from OpenStreetMap through the Overpass API (spec section 3)."""

from __future__ import annotations

from collections.abc import Callable
import json
import logging
import time

import httpx

from app.models.resort import Resort
from app.models.resort_lift import ResortLift
from app.repositories.protocols import ResortLiftRepositoryProtocol
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.osm_lift_mapping import OsmLift
from app.services.osm_lift_mapping import map_overpass_ways

logger = logging.getLogger(__name__)

_USER_AGENT = "FallLine/1.0 (+local)"
_PACE_SECONDS = 1.0


class OsmLiftCatalogService:
    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: int,
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._base_url = base_url
        self._timeout_seconds = timeout_seconds
        self._client = client
        self._sleep = sleep

    def fetch_lifts(self, *, latitude: float, longitude: float, radius_m: int) -> list[OsmLift]:
        query = (
            f"[out:json][timeout:{self._timeout_seconds}];"
            f'way["aerialway"](around:{int(radius_m)},{latitude},{longitude});'
            "out geom;"
        )
        try:
            if self._client is not None:
                response = self._client.post(
                    self._base_url, data={"data": query}, headers={"User-Agent": _USER_AGENT}
                )
            else:
                with httpx.Client(timeout=float(self._timeout_seconds)) as client:
                    response = client.post(
                        self._base_url, data={"data": query}, headers={"User-Agent": _USER_AGENT}
                    )
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPError as exc:
            raise ServiceUnavailableError("Overpass API unavailable.") from exc
        except ValueError as exc:
            raise ValidationError("Overpass API returned invalid JSON.") from exc
        finally:
            self._sleep(_PACE_SECONDS)
        if not isinstance(payload, dict):
            raise ValidationError("Overpass API returned an unexpected payload.")
        lifts = map_overpass_ways(payload)
        logger.info(
            "Overpass returned %d usable lifts around %.4f, %.4f", len(lifts), latitude, longitude
        )
        return lifts

    def import_for_resort(
        self, resort: Resort, repository: ResortLiftRepositoryProtocol, *, radius_m: int
    ) -> int:
        if resort.latitude is None or resort.longitude is None:
            raise ValidationError("Resort has no coordinates; cannot import lifts.")
        lifts = self.fetch_lifts(
            latitude=float(resort.latitude), longitude=float(resort.longitude), radius_m=radius_m
        )
        rows = [
            ResortLift(
                resort_id=resort.id,
                name=lift.name,
                lift_type=lift.lift_type,
                osm_aerialway=lift.osm_aerialway,
                polyline=json.dumps([[lat, lon] for lat, lon in lift.polyline]),
                base_altitude_m=lift.base_altitude_m,
                top_altitude_m=lift.top_altitude_m,
                external_track_id=lift.external_track_id,
            )
            for lift in lifts
        ]
        count = repository.upsert_by_external_track_id(resort.id, rows)
        repository.commit()
        return count
