"""Fetch and stream the OpenSkiData snapshot (spec 5.1). No business rules beyond filters."""

from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime
import json
import logging
from pathlib import Path
import shutil
import tempfile
from types import TracebackType
from typing import Any

import httpx
import ijson

from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import ExternalLiftRecord
from app.services.catalog_types import ExternalSourceRecord
from app.services.catalog_types import content_hash
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.openskidata_mapping import ACTIVE_STATUSES
from app.services.openskidata_mapping import map_lift
from app.services.openskidata_mapping import map_ski_area
from app.services.openskidata_mapping import ski_area_external_id

logger = logging.getLogger(__name__)

METADATA_FILE = "metadata.json"
SKI_AREAS_FILE = "ski_areas.geojson"
LIFTS_FILE = "lifts.geojson"
_REMOTE_PATHS = {
    METADATA_FILE: "/metadata.json",
    SKI_AREAS_FILE: "/geojson/ski_areas.geojson",
    LIFTS_FILE: "/geojson/lifts.geojson",
}
_USER_AGENT = "FallLine/1.0 (+catalog-import)"
_DOWNHILL = "downhill"


class OpenSkiDataSource:
    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: int,
        client: httpx.Client | None = None,
        local_dir: Path | None = None,
        countries: frozenset[str] | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._timeout_seconds = timeout_seconds
        self._client = client
        self._local_dir = local_dir
        self._countries = countries
        self._temp_dir: Path | None = None
        self._kept_ski_area_ids: set[str] = set()
        self._snapshot_built_at: datetime | None = None
        self._metadata_loaded = False

    def __enter__(self) -> OpenSkiDataSource:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def close(self) -> None:
        if self._temp_dir is not None:
            shutil.rmtree(self._temp_dir, ignore_errors=True)
            self._temp_dir = None

    def snapshot_built_at(self) -> datetime | None:
        if not self._metadata_loaded:
            self._metadata_loaded = True
            self._snapshot_built_at = _parse_metadata(self._ensure_file(METADATA_FILE))
        return self._snapshot_built_at

    def iter_ski_areas(self) -> Iterator[ExternalSourceRecord]:
        built_at = self.snapshot_built_at()
        self._kept_ski_area_ids = set()
        kept: list[ExternalSourceRecord] = []
        for feature in _iter_features(self._ensure_file(SKI_AREAS_FILE)):
            view = map_ski_area(feature)
            if _DOWNHILL not in view.activities:
                continue
            if view.status is not None and view.status not in ACTIVE_STATUSES:
                continue
            if self._countries is not None and view.country_code not in self._countries:
                continue
            external_id = ski_area_external_id(feature)
            kept.append(
                ExternalSourceRecord(
                    source=SOURCE_OPENSKIDATA,
                    external_id=external_id,
                    payload=feature,
                    content_hash=content_hash(feature),
                    snapshot_built_at=built_at,
                )
            )
        kept.sort(key=lambda record: record.external_id)
        for record in kept:
            self._kept_ski_area_ids.add(record.external_id)
            yield record

    def iter_lifts(self) -> Iterator[ExternalLiftRecord]:
        for feature in _iter_features(self._ensure_file(LIFTS_FILE)):
            lift = map_lift(feature)
            if lift is None:
                continue
            if lift.status is not None and lift.status not in ACTIVE_STATUSES:
                continue
            if self._countries is not None and not (
                set(lift.ski_area_ids) & self._kept_ski_area_ids
            ):
                continue
            yield lift

    def _ensure_file(self, name: str) -> Path:
        if self._local_dir is not None:
            path = self._local_dir / name
            if not path.exists():
                raise ValidationError(f"OpenSkiData file is missing: {path}")
            return path
        if self._temp_dir is None:
            self._temp_dir = Path(tempfile.mkdtemp(prefix="openskidata-"))
        target = self._temp_dir / name
        if target.exists():
            return target
        self._download(name, target)
        return target

    def _download(self, name: str, target: Path) -> None:
        url = f"{self._base_url}{_REMOTE_PATHS[name]}"
        logger.info("Downloading %s", url)
        try:
            if self._client is not None:
                _stream_to_file(self._client, url, target)
            else:
                with httpx.Client(timeout=float(self._timeout_seconds)) as client:
                    _stream_to_file(client, url, target)
        except httpx.HTTPError as exc:
            target.unlink(missing_ok=True)
            raise ServiceUnavailableError("OpenSkiData download failed.") from exc


def _stream_to_file(client: httpx.Client, url: str, target: Path) -> None:
    with client.stream("GET", url, headers={"User-Agent": _USER_AGENT}) as response:
        response.raise_for_status()
        with target.open("wb") as handle:
            for chunk in response.iter_bytes():
                handle.write(chunk)


def _parse_metadata(path: Path) -> datetime | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise ValidationError("OpenSkiData metadata.json is not valid JSON.") from exc
    run = payload.get("run") if isinstance(payload, dict) else None
    finished = run.get("finishedAt") if isinstance(run, dict) else None
    if not isinstance(finished, str):
        return None
    try:
        return datetime.fromisoformat(finished.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError("OpenSkiData metadata.json has an invalid finishedAt.") from exc


def _iter_features(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open("rb") as handle:
            for feature in ijson.items(handle, "features.item", use_float=True):
                if isinstance(feature, dict):
                    yield feature
    except (ijson.JSONError, ValueError) as exc:
        raise ValidationError("OpenSkiData file is not valid GeoJSON.") from exc
