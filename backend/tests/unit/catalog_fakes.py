"""In-memory repositories and a fixture-backed source for catalog service tests."""

from __future__ import annotations

from collections.abc import Collection
from collections.abc import Iterator
from collections.abc import Sequence
from datetime import datetime
from pathlib import Path
from typing import Any
import uuid

from app.models.resort import Resort
from app.models.resort_field_override import ResortFieldOverride
from app.models.resort_lift import ResortLift
from app.models.resort_source_record import ResortSourceRecord
from app.services.catalog_types import ExternalLiftRecord
from app.services.catalog_types import ExternalSourceRecord
from app.services.openskidata_source import OpenSkiDataSource

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "openskidata"


class FakeResortRepository:
    def __init__(self, resorts: list[Resort] | None = None) -> None:
        self.resorts = resorts or []
        self.commits = 0
        self.linked_records: list[ResortSourceRecord] = []  # shared with FakeRecordRepository
        self.dirty: set[uuid.UUID] = set()  # ids a test wants re-merged
        # Snapshot of each resort's linked record ids as of its last merge, so that a later
        # source linking a new record to an already-merged resort is picked up as stale too
        # (real repo detects this via record.updated_at > resort.last_merged_at; the fake's
        # frozen test clock can't, so it compares linkage membership instead).
        self._merged_signature: dict[uuid.UUID, frozenset[uuid.UUID]] = {}

    def add(self, resort: Resort) -> None:
        if resort.id is None:
            resort.id = uuid.uuid4()
        if resort.name_aliases is None:
            resort.name_aliases = []
        if resort.field_provenance is None:
            resort.field_provenance = {}
        self.resorts.append(resort)

    def flush(self) -> None:
        pass

    def commit(self) -> None:
        self.commits += 1

    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        return next((r for r in self.resorts if r.id == resort_id), None)

    def get_by_name(self, name: str) -> Resort | None:
        return next((r for r in self.resorts if r.name.lower() == name.strip().lower()), None)

    def list_all_for_matching(self) -> list[Resort]:
        return sorted(self.resorts, key=lambda r: str(r.id))

    def list_without_source(self, source: str) -> list[Resort]:
        linked = {
            r.resort_id
            for r in self.linked_records
            if r.source == source and r.match_status == "linked" and r.resort_id is not None
        }
        return [r for r in self.list_all_for_matching() if r.id not in linked]

    def list_stale_for_merge(self) -> list[Resort]:
        def linked_record_ids(resort_id: uuid.UUID) -> frozenset[uuid.UUID]:
            return frozenset(
                r.id
                for r in self.linked_records
                if r.resort_id == resort_id and r.match_status == "linked"
            )

        stale = []
        for r in self.list_all_for_matching():
            current = linked_record_ids(r.id)
            if (
                r.last_merged_at is None
                or r.id in self.dirty
                or self._merged_signature.get(r.id) != current
            ):
                stale.append(r)
                self._merged_signature[r.id] = current
        self.dirty.clear()
        return stale


class FakeRecordRepository:
    def __init__(
        self,
        records: list[ResortSourceRecord] | None = None,
        resorts: FakeResortRepository | None = None,
    ) -> None:
        self.records = records or []
        self.commits = 0
        self.rollbacks = 0
        if resorts is not None:
            resorts.linked_records = self.records

    def get_by_source_and_external_id(
        self, source: str, external_id: str
    ) -> ResortSourceRecord | None:
        return next(
            (r for r in self.records if r.source == source and r.external_id == external_id), None
        )

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortSourceRecord]:
        return sorted(
            (r for r in self.records if r.resort_id == resort_id),
            key=lambda r: (r.source, r.external_id),
        )

    def list_by_source(self, source: str) -> list[ResortSourceRecord]:
        return sorted((r for r in self.records if r.source == source), key=lambda r: r.external_id)

    def list_pending_review(self, source: str | None = None) -> list[ResortSourceRecord]:
        return sorted(
            (
                r
                for r in self.records
                if r.match_status == "pending_review" and (source is None or r.source == source)
            ),
            key=lambda r: (r.source, r.external_id),
        )

    def list_unlinked(self, source: str) -> list[ResortSourceRecord]:
        return [r for r in self.list_pending_review(source) if r.resort_id is None]

    def add(self, record: ResortSourceRecord) -> None:
        if record.id is None:
            record.id = uuid.uuid4()
        self.records.append(record)

    def mark_missing_except(
        self, source: str, seen_external_ids: Collection[str], missing_since: datetime
    ) -> int:
        count = 0
        for record in self.records:
            if (
                record.source == source
                and record.missing_since is None
                and record.external_id not in seen_external_ids
            ):
                record.missing_since = missing_since
                count += 1
        return count

    def flush(self) -> None:
        pass

    def commit(self) -> None:
        self.commits += 1

    def rollback(self) -> None:
        self.rollbacks += 1


class FakeOverrideRepository:
    def __init__(self, overrides: list[ResortFieldOverride] | None = None) -> None:
        self.overrides = overrides or []

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortFieldOverride]:
        return [o for o in self.overrides if o.resort_id == resort_id]

    def upsert(
        self, resort_id: uuid.UUID, field: str, value: Any, note: str | None
    ) -> ResortFieldOverride:
        for existing in self.overrides:
            if existing.resort_id == resort_id and existing.field == field:
                existing.value = value
                existing.note = note
                return existing
        override = ResortFieldOverride(resort_id=resort_id, field=field, value=value, note=note)
        self.overrides.append(override)
        return override

    def delete(self, resort_id: uuid.UUID, field: str) -> int:
        before = len(self.overrides)
        self.overrides = [
            o for o in self.overrides if not (o.resort_id == resort_id and o.field == field)
        ]
        return before - len(self.overrides)

    def commit(self) -> None:
        pass


class FakeLiftRepository:
    def __init__(self, lifts: list[ResortLift] | None = None) -> None:
        self.lifts = lifts or []

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortLift]:
        return sorted(
            (lift for lift in self.lifts if lift.resort_id == resort_id), key=lambda lift: lift.name
        )

    def match_track_id(self, track_id: str) -> ResortLift | None:
        return next((lift for lift in self.lifts if lift.external_track_id == track_id), None)

    def upsert_by_external_track_id(self, resort_id: uuid.UUID, rows: Sequence[ResortLift]) -> int:
        count = 0
        for row in rows:
            if row.external_track_id is None:
                continue
            existing = next(
                (
                    lift
                    for lift in self.lifts
                    if lift.resort_id == resort_id
                    and lift.external_track_id == row.external_track_id
                ),
                None,
            )
            if existing is None:
                row.resort_id = resort_id
                self.lifts.append(row)
            else:
                existing.name = row.name
                existing.lift_type = row.lift_type
                existing.osm_aerialway = row.osm_aerialway
                existing.polyline = row.polyline
                existing.base_altitude_m = row.base_altitude_m
                existing.top_altitude_m = row.top_altitude_m
                existing.status = row.status
                if row.source is not None:
                    existing.source = row.source
                existing.source_record_id = row.source_record_id
            count += 1
        return count

    def delete_missing_for_resort(
        self, resort_id: uuid.UUID, keep_track_ids: Collection[str], source: str
    ) -> int:
        before = len(self.lifts)
        self.lifts = [
            lift
            for lift in self.lifts
            if not (
                lift.resort_id == resort_id
                and lift.source == source
                and lift.external_track_id not in keep_track_ids
            )
        ]
        return before - len(self.lifts)

    def delete_by_source_for_resort(self, resort_id: uuid.UUID, source: str) -> int:
        before = len(self.lifts)
        self.lifts = [
            lift
            for lift in self.lifts
            if not (lift.resort_id == resort_id and lift.source == source)
        ]
        return before - len(self.lifts)

    def commit(self) -> None:
        pass


class FixtureOpenSkiDataSource:
    """Reads the checked-in fixture directory; never touches the network."""

    def __init__(self, countries: frozenset[str] | None = None) -> None:
        self._inner = OpenSkiDataSource(
            base_url="https://unused.test",
            timeout_seconds=1,
            local_dir=FIXTURES,
            countries=countries,
        )

    def snapshot_built_at(self) -> datetime | None:
        return self._inner.snapshot_built_at()

    def iter_ski_areas(self) -> Iterator[ExternalSourceRecord]:
        return self._inner.iter_ski_areas()

    def iter_lifts(self) -> Iterator[ExternalLiftRecord]:
        return self._inner.iter_lifts()
