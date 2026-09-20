from datetime import UTC
from datetime import datetime
import json
import uuid

from app.models.resort import Resort
from app.models.resort_lift import ResortLift
from app.models.resort_source_record import ResortSourceRecord
from app.services.resort_lift_sync_service import ResortLiftSyncService
from tests.unit.catalog_fakes import FakeLiftRepository
from tests.unit.catalog_fakes import FakeRecordRepository
from tests.unit.catalog_fakes import FixtureOpenSkiDataSource

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def _linked(external_id: str, resort: Resort) -> ResortSourceRecord:
    return ResortSourceRecord(
        id=uuid.uuid4(),
        source="openskidata",
        external_id=external_id,
        payload={},
        content_hash="h",
        fetched_at=NOW,
        resort_id=resort.id,
        match_status="linked",
        match_method="primary",
    )


def test_sync_writes_lifts_for_linked_areas_only_and_replaces_overpass_rows() -> None:
    grouse = Resort(id=uuid.uuid4(), name="Grouse Mountain", country="Canada", region="BC")
    seymour = Resort(id=uuid.uuid4(), name="Mount Seymour", country="Canada", region="BC")
    legacy = ResortLift(
        resort_id=grouse.id,
        name="Old Overpass Chair",
        external_track_id="osm:way:999",
        source="overpass",
    )
    records = FakeRecordRepository([_linked("osd-grouse", grouse), _linked("osd-seymour", seymour)])
    lifts = FakeLiftRepository([legacy])
    source = FixtureOpenSkiDataSource()
    list(source.iter_ski_areas())

    summary = ResortLiftSyncService(record_repository=records, lift_repository=lifts).sync(
        source.iter_lifts()
    )  # type: ignore[arg-type]

    grouse_tracks = sorted(lift.external_track_id or "" for lift in lifts.list_by_resort(grouse.id))
    seymour_tracks = sorted(
        lift.external_track_id or "" for lift in lifts.list_by_resort(seymour.id)
    )
    assert grouse_tracks == ["osm:way:1001", "osm:way:1002", "osm:way:1003"]
    assert seymour_tracks == ["osm:way:3001", "osm:way:3002", "osm:way:5001"]
    assert summary.upserted == 6
    assert summary.skipped_unlinked == 3  # 2001, 2002 and the cypress half of 5001
    assert all(lift.source == "openskidata" for lift in lifts.lifts)
    skyride = next(lift for lift in lifts.lifts if lift.external_track_id == "osm:way:1002")
    assert json.loads(skyride.polyline or "[]") == [[49.373, -123.089], [49.380, -123.081]]
    assert (skyride.base_altitude_m, skyride.top_altitude_m) == (290.0, 1100.0)
    assert skyride.lift_type == "gondola" and skyride.status == "operating"
    assert (
        skyride.source_record_id
        == records.get_by_source_and_external_id("openskidata", "osd-grouse").id
    )  # type: ignore[union-attr]


def test_sync_deletes_openskidata_lifts_missing_from_snapshot() -> None:
    grouse = Resort(id=uuid.uuid4(), name="Grouse Mountain", country="Canada", region="BC")
    stale = ResortLift(
        resort_id=grouse.id, name="Removed", external_track_id="osm:way:777", source="openskidata"
    )
    records = FakeRecordRepository([_linked("osd-grouse", grouse)])
    lifts = FakeLiftRepository([stale])
    source = FixtureOpenSkiDataSource()
    list(source.iter_ski_areas())

    summary = ResortLiftSyncService(record_repository=records, lift_repository=lifts).sync(
        source.iter_lifts()
    )  # type: ignore[arg-type]

    assert summary.deleted == 1
    assert "osm:way:777" not in {lift.external_track_id for lift in lifts.lifts}


def test_sync_removes_all_lifts_for_area_missing_entirely_from_snapshot() -> None:
    grouse = Resort(id=uuid.uuid4(), name="Grouse Mountain", country="Canada", region="BC")
    lift_a = ResortLift(
        resort_id=grouse.id, name="A", external_track_id="osm:way:1001", source="openskidata"
    )
    lift_b = ResortLift(
        resort_id=grouse.id, name="B", external_track_id="osm:way:1002", source="openskidata"
    )
    records = FakeRecordRepository([_linked("osd-grouse", grouse)])
    lifts = FakeLiftRepository([lift_a, lift_b])

    summary = ResortLiftSyncService(record_repository=records, lift_repository=lifts).sync([])

    assert lifts.list_by_resort(grouse.id) == []
    assert summary.upserted == 0
    assert summary.deleted == 2


def test_sync_keeps_lifts_for_area_marked_missing() -> None:
    grouse = Resort(id=uuid.uuid4(), name="Grouse Mountain", country="Canada", region="BC")
    lift_a = ResortLift(
        resort_id=grouse.id, name="A", external_track_id="osm:way:1001", source="openskidata"
    )
    record = _linked("osd-grouse", grouse)
    record.missing_since = NOW
    records = FakeRecordRepository([record])
    lifts = FakeLiftRepository([lift_a])

    summary = ResortLiftSyncService(record_repository=records, lift_repository=lifts).sync([])

    assert [lift.external_track_id for lift in lifts.list_by_resort(grouse.id)] == ["osm:way:1001"]
    assert summary.deleted == 0


def test_empty_snapshot_for_a_resort_keeps_its_overpass_lifts() -> None:
    grouse = Resort(id=uuid.uuid4(), name="Grouse Mountain", country="Canada", region="BC")
    overpass = ResortLift(
        resort_id=grouse.id,
        name="Old Overpass Chair",
        external_track_id="osm:way:999",
        source="overpass",
    )
    records = FakeRecordRepository([_linked("osd-grouse", grouse)])
    lifts = FakeLiftRepository([overpass])

    summary = ResortLiftSyncService(record_repository=records, lift_repository=lifts).sync([])

    # Nothing replaced them, so the legacy catalog survives instead of leaving the resort liftless.
    assert [lift.external_track_id for lift in lifts.list_by_resort(grouse.id)] == ["osm:way:999"]
    assert summary.deleted == 0
