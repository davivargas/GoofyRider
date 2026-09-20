from datetime import UTC
from datetime import datetime
import uuid

import pytest

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_review_service import ResortReviewService
from tests.unit.catalog_fakes import FakeLiftRepository
from tests.unit.catalog_fakes import FakeOverrideRepository
from tests.unit.catalog_fakes import FakeRecordRepository
from tests.unit.catalog_fakes import FakeResortRepository

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def _feature(name: str, lat: float, lon: float) -> dict[str, object]:
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [lon, lat]},
        "properties": {
            "type": "skiArea",
            "id": "osd-x",
            "name": name,
            "activities": ["downhill"],
            "status": "operating",
            "sources": [],
            "statistics": None,
            "places": [
                {
                    "iso3166_1Alpha2": "CA",
                    "iso3166_2": "CA-BC",
                    "localized": {
                        "en": {"country": "Canada", "region": "British Columbia", "locality": None}
                    },
                }
            ],
        },
    }


def _pending(external_id: str = "osd-x") -> ResortSourceRecord:
    return ResortSourceRecord(
        id=uuid.uuid4(),
        source="openskidata",
        external_id=external_id,
        payload=_feature("Big White", 49.72, -118.93),
        content_hash="h",
        fetched_at=NOW,
        match_status="pending_review",
        match_candidates=[{"resort_id": "x", "name": "Big White", "score": 0.7}],
    )


def _build(resorts: list[Resort], records: list[ResortSourceRecord]):  # type: ignore[no-untyped-def]
    resort_repo = FakeResortRepository(resorts)
    record_repo = FakeRecordRepository(records, resorts=resort_repo)
    lift_repo = FakeLiftRepository()
    merge = ResortMergeService(
        resort_repo,  # type: ignore[arg-type]
        record_repo,
        FakeOverrideRepository(),
        lift_repo,
        clock=lambda: NOW,
    )
    service = ResortReviewService(
        resort_repository=resort_repo,  # type: ignore[arg-type]
        record_repository=record_repo,
        merge_service=merge,
    )
    return service, resort_repo, record_repo


def test_list_pending_reports_name_and_candidates() -> None:
    service, _, _ = _build([], [_pending()])

    items = service.list_pending(None)

    assert len(items) == 1
    assert (items[0].source, items[0].external_id, items[0].name) == (
        "openskidata",
        "osd-x",
        "Big White",
    )
    assert items[0].candidates[0]["name"] == "Big White"


def test_link_sets_manual_and_merges_resort() -> None:
    resort = Resort(
        id=uuid.uuid4(),
        name="Old",
        country="Old",
        region="Old",
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    record = _pending()
    service, resort_repo, _ = _build([resort], [record])

    service.link("openskidata", "osd-x", resort.id)

    assert (record.match_status, record.match_method, record.resort_id) == (
        "linked",
        "manual",
        resort.id,
    )
    assert record.match_candidates is None
    assert resort.name == "Big White" and resort.field_provenance["name"] == "openskidata"
    assert resort_repo.commits == 1


def test_link_refuses_second_openskidata_record_for_same_resort() -> None:
    resort = Resort(
        id=uuid.uuid4(),
        name="Big White",
        country="Canada",
        region="BC",
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    linked = ResortSourceRecord(
        id=uuid.uuid4(),
        source="openskidata",
        external_id="osd-first",
        payload=_feature("Big White", 49.72, -118.93),
        content_hash="h",
        fetched_at=NOW,
        resort_id=resort.id,
        match_status="linked",
        match_method="primary",
    )
    service, _, _ = _build([resort], [linked, _pending("osd-second")])

    with pytest.raises(ConflictError):
        service.link("openskidata", "osd-second", resort.id)


def test_link_unknown_record_or_resort_raises_not_found() -> None:
    service, _, _ = _build([], [_pending()])

    with pytest.raises(NotFoundError):
        service.link("openskidata", "nope", uuid.uuid4())
    with pytest.raises(NotFoundError):
        service.link("openskidata", "osd-x", uuid.uuid4())


def test_reject_and_create() -> None:
    record = _pending()
    service, resort_repo, _ = _build([], [record])

    new_id = service.create("openskidata", "osd-x")

    created = resort_repo.get_by_id(new_id)
    assert created is not None and created.name == "Big White"
    assert (record.match_status, record.match_method, record.resort_id) == (
        "linked",
        "manual",
        new_id,
    )

    other = _pending("osd-y")
    service2, resort_repo2, _ = _build([], [other])
    service2.reject("openskidata", "osd-y")
    assert (other.match_status, other.resort_id, other.match_candidates) == ("rejected", None, None)
    assert resort_repo2.commits == 1


def test_actions_require_pending_status() -> None:
    record = _pending()
    record.match_status = "rejected"
    service, _, _ = _build([], [record])

    with pytest.raises(ValidationError):
        service.create("openskidata", "osd-x")


def test_list_legacy_reports_candidates_that_list_pending_cannot_show() -> None:
    legacy = ResortSourceRecord(
        id=uuid.uuid4(),
        source="ski_api",
        external_id="big-white",
        payload={"slug": "big-white", "name": "Big White", "country": "CA", "region": "BC"},
        content_hash="h",
        fetched_at=NOW,
        resort_id=uuid.uuid4(),
        match_status="linked",
        match_method="legacy",
        match_candidates=[
            {
                "resort_id": "r-1",
                "name": "Big White Ski Resort",
                "score": 0.62,
                "external_id": "osd-big-white",
                "linked_resort_id": None,
            }
        ],
    )
    service, _, _ = _build([], [legacy, _pending()])

    assert [i.external_id for i in service.list_pending(None)] == ["osd-x"]  # legacy is invisible
    items = service.list_legacy()

    assert len(items) == 1
    assert (items[0].source, items[0].external_id, items[0].name) == (
        "ski_api",
        "big-white",
        "Big White",
    )
    assert items[0].candidates[0]["external_id"] == "osd-big-white"
    assert items[0].candidates[0]["linked_resort_id"] is None
