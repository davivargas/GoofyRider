from datetime import UTC
from datetime import datetime
import uuid

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.services.resort_catalog_import_service import CatalogImportOptions
from app.services.resort_catalog_import_service import ResortCatalogImportService
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_source_record_service import ResortSourceRecordService
from tests.unit.catalog_fakes import FakeLiftRepository
from tests.unit.catalog_fakes import FakeOverrideRepository
from tests.unit.catalog_fakes import FakeRecordRepository
from tests.unit.catalog_fakes import FakeResortRepository
from tests.unit.catalog_fakes import FixtureOpenSkiDataSource

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def _build(resorts: list[Resort], records: list[ResortSourceRecord]):  # type: ignore[no-untyped-def]
    resort_repo = FakeResortRepository(resorts)
    record_repo = FakeRecordRepository(records, resorts=resort_repo)
    override_repo = FakeOverrideRepository()
    lift_repo = FakeLiftRepository()
    service = ResortCatalogImportService(
        resort_repository=resort_repo,  # type: ignore[arg-type]
        record_repository=record_repo,  # type: ignore[arg-type]
        override_repository=override_repo,  # type: ignore[arg-type]
        lift_repository=lift_repo,  # type: ignore[arg-type]
        record_service=ResortSourceRecordService(record_repo, clock=lambda: NOW),  # type: ignore[arg-type]
        merge_service=ResortMergeService(
            resort_repo, record_repo, override_repo, lift_repo, clock=lambda: NOW
        ),  # type: ignore[arg-type]
        lift_sync_service=ResortLiftSyncService(record_repo, lift_repo),  # type: ignore[arg-type]
        clock=lambda: NOW,
    )
    return service, resort_repo, record_repo, lift_repo


def _legacy(resort: Resort, slug: str) -> ResortSourceRecord:
    return ResortSourceRecord(
        id=uuid.uuid4(),
        source="ski_api",
        external_id=slug,
        payload={
            "legacy": True,
            "name": resort.name,
            "country": resort.country,
            "region": resort.region,
            "latitude": resort.latitude,
            "longitude": resort.longitude,
        },
        content_hash="legacy",
        fetched_at=NOW,
        resort_id=resort.id,
        match_status="linked",
        match_method="legacy",
    )


def test_first_import_links_legacy_rows_creates_new_resorts_and_writes_lifts() -> None:
    grouse = Resort(
        id=uuid.uuid4(),
        name="Grouse Mountain",
        country="Canada",
        region="British Columbia",
        latitude=49.380,
        longitude=-123.081,
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    orphan = Resort(
        id=uuid.uuid4(),
        name="Big White",
        country="Canada",
        region="British Columbia",
        latitude=49.72,
        longitude=-118.93,
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    service, resort_repo, record_repo, lift_repo = _build(
        [grouse, orphan], [_legacy(grouse, "grouse-mountain"), _legacy(orphan, "big-white")]
    )

    summary = service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())

    assert summary.records.created == 4
    assert summary.linked_auto == 1 and summary.linked_primary == 3
    assert grouse.id in {r.id for r in resort_repo.resorts}  # UUID preserved
    grouse_record = record_repo.get_by_source_and_external_id("openskidata", "osd-grouse")
    assert (
        grouse_record is not None
        and grouse_record.resort_id == grouse.id
        and grouse_record.match_method == "auto"
    )
    names = sorted(r.name for r in resort_repo.resorts)
    assert names == [
        "Big White",
        "Cypress Mountain",
        "Grouse Mountain",
        "Grouse Mountain",
        "Mount Seymour",
    ]
    assert grouse.city == "North Vancouver" and grouse.boundary is not None
    assert grouse.field_provenance["name"] == "openskidata"
    assert summary.pending_review == 0
    assert (
        summary.lifts is not None and summary.lifts.upserted == 9
    )  # 3 + 3 + 3, shared T-bar twice
    assert len(lift_repo.list_by_resort(grouse.id)) == 3
    assert orphan.is_active is True
    assert resort_repo.commits >= 1


def test_legacy_row_without_match_is_listed_for_review_not_orphaned() -> None:
    orphan = Resort(
        id=uuid.uuid4(),
        name="Big White",
        country="Canada",
        region="British Columbia",
        latitude=49.72,
        longitude=-118.93,
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    service, _, record_repo, _ = _build([orphan], [_legacy(orphan, "big-white")])

    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    reviewed = service.review_legacy_resorts()

    assert reviewed == 1
    legacy = record_repo.get_by_source_and_external_id("ski_api", "big-white")
    assert legacy is not None and legacy.match_status == "linked"  # the legacy link itself stays
    assert legacy.match_candidates is not None  # candidates recorded for the operator
    assert {c["external_id"] for c in legacy.match_candidates} <= {
        "osd-cypress",
        "osd-grouse",
        "osd-grouse-us",
        "osd-seymour",
    }
    assert all("linked_resort_id" in c for c in legacy.match_candidates)


def test_second_run_is_a_no_op() -> None:
    service, resort_repo, _record_repo, _lift_repo = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    snapshot = sorted((r.name, r.city, r.elevation_top_m, r.is_active) for r in resort_repo.resorts)

    summary = service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())

    assert (summary.records.created, summary.records.updated, summary.records.unchanged) == (
        0,
        0,
        4,
    )
    assert summary.linked_auto == 0 and summary.linked_primary == 0
    assert summary.merge.changed_count == 0
    assert (
        sorted((r.name, r.city, r.elevation_top_m, r.is_active) for r in resort_repo.resorts)
        == snapshot
    )


def test_missing_record_deactivates_resort_on_next_run() -> None:
    service, resort_repo, _record_repo, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    grouse_us = next(r for r in resort_repo.resorts if r.country_code == "US")
    resort_repo.dirty.add(grouse_us.id)

    summary = service.import_openskidata(
        FixtureOpenSkiDataSource(countries=frozenset({"CA"})), CatalogImportOptions()
    )

    assert summary.records.marked_missing == 1
    assert grouse_us.is_active is False


def test_manual_and_rejected_records_are_never_rematched() -> None:
    service, _resort_repo, record_repo, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    cypress_record = record_repo.get_by_source_and_external_id("openskidata", "osd-cypress")
    assert cypress_record is not None
    cypress_record.match_method = "manual"
    seymour_record = record_repo.get_by_source_and_external_id("openskidata", "osd-seymour")
    assert seymour_record is not None
    seymour_record.match_status = "rejected"
    seymour_record.resort_id = None

    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions(rematch=True))

    assert cypress_record.match_method == "manual"
    assert seymour_record.match_status == "rejected" and seymour_record.resort_id is None


def test_dry_run_does_not_commit() -> None:
    service, resort_repo, _, _ = _build([], [])

    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions(dry_run=True))

    assert resort_repo.commits == 0
