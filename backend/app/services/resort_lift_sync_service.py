"""Pass 2 of the import: OpenSkiData lifts into resort_lifts for linked ski areas (spec 5.3)."""

from __future__ import annotations

from collections.abc import Iterable
from collections.abc import Sequence
from dataclasses import dataclass
import json
import logging

from app.models.resort_lift import ResortLift
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.protocols import ResortLiftRepositoryProtocol
from app.repositories.protocols import ResortSourceRecordRepositoryProtocol
from app.services.catalog_types import LIFT_SOURCE_OPENSKIDATA
from app.services.catalog_types import LIFT_SOURCE_OVERPASS
from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import ExternalLiftRecord
from app.services.exceptions import ValidationError

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class LiftSyncSummary:
    upserted: int
    deleted: int
    skipped_unlinked: int


class ResortLiftSyncService:
    def __init__(
        self,
        record_repository: ResortSourceRecordRepositoryProtocol,
        lift_repository: ResortLiftRepositoryProtocol,
    ) -> None:
        self._records = record_repository
        self._lifts = lift_repository

    def sync(self, lifts: Iterable[ExternalLiftRecord]) -> LiftSyncSummary:
        by_area: dict[str, list[ExternalLiftRecord]] = {}
        for lift in lifts:
            for area_id in lift.ski_area_ids:
                by_area.setdefault(area_id, []).append(lift)

        upserted = deleted = skipped = 0
        for area_id in sorted(by_area):
            record = self._records.get_by_source_and_external_id(SOURCE_OPENSKIDATA, area_id)
            if record is None or record.match_status != "linked" or record.resort_id is None:
                skipped += len(by_area[area_id])
                continue
            count, removed = self._write(record, by_area[area_id])
            upserted += count
            deleted += removed

        # Areas that dropped to zero lifts in this snapshot never appear in `by_area`, so they
        # would otherwise keep their stale openskidata rows forever. Records marked missing are
        # skipped on purpose: a --countries run marks out-of-filter areas missing before the
        # sync, so their lifts must survive.
        for record in self._records.list_by_source(SOURCE_OPENSKIDATA):
            if (
                record.match_status == "linked"
                and record.resort_id is not None
                and record.missing_since is None
                and record.external_id not in by_area
            ):
                _, removed = self._write(record, [])
                deleted += removed
        return LiftSyncSummary(upserted=upserted, deleted=deleted, skipped_unlinked=skipped)

    def _write(
        self, record: ResortSourceRecord, lifts: Sequence[ExternalLiftRecord]
    ) -> tuple[int, int]:
        if record.resort_id is None:
            raise ValidationError("Source record is not linked to a resort.")
        resort_id = record.resort_id
        rows = [
            ResortLift(
                resort_id=resort_id,
                name=lift.name,
                lift_type=lift.lift_type,
                osm_aerialway=lift.osm_aerialway,
                polyline=json.dumps([[lat, lon] for lat, lon in lift.polyline]),
                base_altitude_m=lift.base_altitude_m,
                top_altitude_m=lift.top_altitude_m,
                external_track_id=lift.external_track_id,
                status=lift.status,
                source=LIFT_SOURCE_OPENSKIDATA,
                source_record_id=record.id,
            )
            for lift in sorted(lifts, key=lambda item: item.external_track_id)
        ]
        # Overpass rows are the legacy catalog; drop them only when OpenSkiData rows replace
        # them, never when this snapshot simply has no lifts for the resort.
        removed = (
            self._lifts.delete_by_source_for_resort(resort_id, LIFT_SOURCE_OVERPASS) if rows else 0
        )
        count = self._lifts.upsert_by_external_track_id(resort_id, rows)
        removed += self._lifts.delete_missing_for_resort(
            resort_id,
            {row.external_track_id for row in rows if row.external_track_id},
            LIFT_SOURCE_OPENSKIDATA,
        )
        return count, removed
