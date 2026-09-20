from datetime import UTC
from datetime import datetime
import json
import uuid

import pytest

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.services.catalog_types import ExternalSourceRecord
from app.services.catalog_types import content_hash
from app.services.exceptions import ServiceUnavailableError
from app.services.resort_catalog_import_service import CatalogImportOptions
from app.services.resort_catalog_import_service import ResortCatalogImportService
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_source_record_service import ResortSourceRecordService
from tests.unit.catalog_fakes import FIXTURES
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
    service, resort_repo, record_repo, _ = _build([], [])

    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions(dry_run=True))

    assert resort_repo.commits == 0
    assert record_repo.rollbacks == 1


def test_pending_review_when_close_but_not_auto_matching_legacy_resort() -> None:
    grouse_legacy = Resort(
        id=uuid.uuid4(),
        name="Grouse Mountain",
        country="Canada",
        region="British Columbia",
        latitude=49.45,
        longitude=-123.081,
        country_code="CA",
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    service, resort_repo, record_repo, _ = _build(
        [grouse_legacy], [_legacy(grouse_legacy, "grouse-mountain")]
    )

    summary = service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())

    osd_grouse = record_repo.get_by_source_and_external_id("openskidata", "osd-grouse")
    assert osd_grouse is not None
    assert osd_grouse.match_status == "pending_review"
    assert osd_grouse.resort_id is None
    assert osd_grouse.match_method is None
    assert osd_grouse.match_candidates
    first_candidate = osd_grouse.match_candidates[0]
    assert first_candidate["resort_id"] == str(grouse_legacy.id)
    assert first_candidate["score"] == pytest.approx(0.73, abs=0.02)
    linked_to_legacy = [
        r
        for r in record_repo.records
        if r.source == "openskidata"
        and r.resort_id == grouse_legacy.id
        and r.match_status == "linked"
    ]
    assert linked_to_legacy == []
    assert summary.pending_review == 1
    assert grouse_legacy.id in {r.id for r in resort_repo.resorts}


def test_eligible_pool_excludes_resorts_that_already_hold_an_openskidata_record() -> None:
    service, _resort_repo, record_repo, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    grouse_record = record_repo.get_by_source_and_external_id("openskidata", "osd-grouse")
    assert grouse_record is not None
    grouse_resort_id = grouse_record.resort_id
    assert grouse_resort_id is not None

    feature = json.loads((FIXTURES / "ski_areas.geojson").read_text(encoding="utf-8"))
    grouse_feature = next(
        f for f in feature["features"] if f["properties"].get("id") == "osd-grouse"
    )
    dup_payload = json.loads(json.dumps(grouse_feature))
    dup_payload["properties"]["id"] = "osd-grouse-dup"
    dup_record = ResortSourceRecord(
        id=uuid.uuid4(),
        source="openskidata",
        external_id="osd-grouse-dup",
        payload=dup_payload,
        content_hash=content_hash(dup_payload),
        fetched_at=NOW,
        resort_id=None,
        match_status="pending_review",
        match_method=None,
    )
    record_repo.add(dup_record)

    service.link_records("openskidata", CatalogImportOptions())

    # Not auto-linked to Grouse: it either stayed pending or created a separate resort.
    if dup_record.match_status == "linked":
        assert dup_record.resort_id != grouse_resort_id
    else:
        assert dup_record.match_status == "pending_review"
        assert dup_record.resort_id is None
    still_linked_to_grouse = [
        r
        for r in record_repo.records
        if r.source == "openskidata"
        and r.resort_id == grouse_resort_id
        and r.match_status == "linked"
    ]
    assert len(still_linked_to_grouse) == 1


def test_rematch_of_an_auto_linked_record_relinks_the_same_resort() -> None:
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
    service, _resort_repo, record_repo, _ = _build([grouse], [_legacy(grouse, "grouse-mountain")])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    grouse_record = record_repo.get_by_source_and_external_id("openskidata", "osd-grouse")
    assert grouse_record is not None
    assert grouse_record.match_method == "auto"

    auto, primary, pending = service.link_records("openskidata", CatalogImportOptions(rematch=True))

    assert (auto, primary, pending) == (1, 0, 0)
    assert grouse_record.resort_id == grouse.id
    assert grouse_record.match_method == "auto"


class FakeSkiApiSource:
    def __init__(
        self,
        entries: list[dict[str, object]],
        details: dict[str, dict[str, object]],
        fail_slugs: frozenset[str] = frozenset(),
    ) -> None:
        self._entries = entries
        self._details = details
        self._fail_slugs = fail_slugs
        self.detail_calls: list[str] = []

    def iter_records(self):  # type: ignore[no-untyped-def]
        for entry in self._entries:
            yield ExternalSourceRecord(
                "ski_api", str(entry["slug"]), dict(entry), content_hash(entry), None
            )

    def fetch_detail(self, slug: str) -> dict[str, object]:
        self.detail_calls.append(slug)
        if slug in self._fail_slugs:
            raise ServiceUnavailableError("Ski API provider unavailable.")
        return dict(self._details[slug])


def test_ski_api_links_enriches_linked_only_and_never_creates() -> None:
    service, resort_repo, record_repo, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    grouse = next(
        r for r in resort_repo.resorts if r.name == "Grouse Mountain" and r.country_code == "CA"
    )
    source = FakeSkiApiSource(
        entries=[
            {
                "slug": "grouse-mountain",
                "name": "Grouse Mountain Resort",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.3803, "longitude": -123.0815},
            },
            {
                "slug": "big-white",
                "name": "Big White",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.72, "longitude": -118.93},
            },
        ],
        details={
            "grouse-mountain": {
                "slug": "grouse-mountain",
                "name": "Grouse Mountain Resort",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.3803, "longitude": -123.0815},
                "elevation": {"base_m": 274, "top_m": 1250},
                "conditions": {"base": 120},
            }
        },
    )

    summary = service.import_ski_api(source, CatalogImportOptions())

    assert summary.linked_auto == 1 and summary.linked_primary == 0 and summary.pending_review == 1
    assert source.detail_calls == ["grouse-mountain"]
    linked = record_repo.get_by_source_and_external_id("ski_api", "grouse-mountain")
    assert linked is not None and linked.resort_id == grouse.id and "detail" in linked.payload
    assert grouse.name == "Grouse Mountain" and grouse.name_aliases == ["Grouse Mountain Resort"]
    assert (
        grouse.field_provenance["elevation_top_m"] == "openskidata"
    )  # OpenSkiData wins by precedence
    unlinked = record_repo.get_by_source_and_external_id("ski_api", "big-white")
    assert (
        unlinked is not None
        and unlinked.match_status == "pending_review"
        and unlinked.resort_id is None
    )
    assert len(resort_repo.resorts) == 4


def test_ski_api_detail_is_fetched_once() -> None:
    service, _resort_repo, _, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    entry = {
        "slug": "grouse-mountain",
        "name": "Grouse Mountain",
        "country": "CA",
        "region": "BC",
        "location": {"latitude": 49.3803, "longitude": -123.0815},
    }
    source = FakeSkiApiSource([entry], {"grouse-mountain": dict(entry)})

    service.import_ski_api(source, CatalogImportOptions())
    service.import_ski_api(source, CatalogImportOptions())

    assert source.detail_calls == ["grouse-mountain"]


def test_ski_api_detail_fetch_failure_is_isolated_to_the_failing_record() -> None:
    service, resort_repo, record_repo, _ = _build([], [])
    service.import_openskidata(FixtureOpenSkiDataSource(), CatalogImportOptions())
    grouse = next(
        r for r in resort_repo.resorts if r.name == "Grouse Mountain" and r.country_code == "CA"
    )
    cypress = next(r for r in resort_repo.resorts if r.name == "Cypress Mountain")
    source = FakeSkiApiSource(
        entries=[
            {
                "slug": "grouse-mountain",
                "name": "Grouse Mountain",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.3803, "longitude": -123.0815},
            },
            {
                "slug": "cypress-mountain",
                "name": "Cypress Mountain",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.396, "longitude": -123.204},
            },
        ],
        details={
            "cypress-mountain": {
                "slug": "cypress-mountain",
                "name": "Cypress Mountain",
                "country": "CA",
                "region": "BC",
                "location": {"latitude": 49.396, "longitude": -123.204},
                "elevation": {"base_m": 900, "top_m": 1450},
            },
        },
        fail_slugs=frozenset({"grouse-mountain"}),
    )

    summary = service.import_ski_api(source, CatalogImportOptions())

    assert summary.linked_auto == 2  # the run completes normally despite the detail-fetch failure
    assert sorted(source.detail_calls) == ["cypress-mountain", "grouse-mountain"]
    assert resort_repo.commits >= 1  # the run completes and commits despite the failure
    grouse_record = record_repo.get_by_source_and_external_id("ski_api", "grouse-mountain")
    assert (
        grouse_record is not None
        and grouse_record.resort_id == grouse.id
        and grouse_record.match_status == "linked"
        and "detail" not in grouse_record.payload
    )
    cypress_record = record_repo.get_by_source_and_external_id("ski_api", "cypress-mountain")
    assert (
        cypress_record is not None
        and cypress_record.resort_id == cypress.id
        and "detail" in cypress_record.payload
    )
