from datetime import UTC
from datetime import datetime

import pytest

from app.models.resort_source_record import ResortSourceRecord
from app.services.catalog_types import ExternalSourceRecord
from app.services.catalog_types import content_hash
from app.services.exceptions import ValidationError
from app.services.resort_source_record_service import ResortSourceRecordService
from tests.unit.catalog_fakes import FakeRecordRepository

RUN_AT = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)
BUILT_AT = datetime(2026, 9, 18, 23, 29, tzinfo=UTC)


def _external(external_id: str, payload: dict[str, object]) -> ExternalSourceRecord:
    return ExternalSourceRecord(
        source="openskidata",
        external_id=external_id,
        payload=dict(payload),
        content_hash=content_hash(payload),
        snapshot_built_at=BUILT_AT,
    )


def test_upsert_creates_updates_unchanged_and_marks_missing() -> None:
    existing_same = ResortSourceRecord(
        source="openskidata",
        external_id="same",
        payload={"v": 1},
        content_hash=content_hash({"v": 1}),
        fetched_at=RUN_AT,
        match_status="linked",
        match_method="primary",
    )
    existing_changed = ResortSourceRecord(
        source="openskidata",
        external_id="changed",
        payload={"v": 1},
        content_hash=content_hash({"v": 1}),
        fetched_at=RUN_AT,
        match_status="linked",
        match_method="primary",
        missing_since=RUN_AT,
    )
    gone = ResortSourceRecord(
        source="openskidata",
        external_id="gone",
        payload={"v": 1},
        content_hash="x",
        fetched_at=RUN_AT,
        match_status="linked",
        match_method="primary",
    )
    repo = FakeRecordRepository([existing_same, existing_changed, gone])
    service = ResortSourceRecordService(record_repository=repo, clock=lambda: RUN_AT)

    summary = service.upsert_records(
        "openskidata",
        [_external("same", {"v": 1}), _external("changed", {"v": 2}), _external("new", {"v": 3})],
        run_started_at=RUN_AT,
    )

    assert (summary.created, summary.updated, summary.unchanged, summary.marked_missing) == (
        1,
        1,
        1,
        1,
    )
    assert existing_changed.payload == {"v": 2} and existing_changed.missing_since is None
    assert existing_changed.snapshot_built_at == BUILT_AT
    assert gone.missing_since == RUN_AT
    new = repo.get_by_source_and_external_id("openskidata", "new")
    assert new is not None
    assert (new.match_status, new.resort_id, new.match_method) == ("pending_review", None, None)
    assert new.fetched_at == RUN_AT


def test_second_identical_run_changes_nothing() -> None:
    repo = FakeRecordRepository([])
    service = ResortSourceRecordService(record_repository=repo, clock=lambda: RUN_AT)
    records = [_external("a", {"v": 1})]

    service.upsert_records("openskidata", records, run_started_at=RUN_AT)
    summary = service.upsert_records("openskidata", records, run_started_at=RUN_AT)

    assert (summary.created, summary.updated, summary.unchanged, summary.marked_missing) == (
        0,
        0,
        1,
        0,
    )


def test_upsert_raises_validation_error_on_source_mismatch() -> None:
    repo = FakeRecordRepository([])
    service = ResortSourceRecordService(record_repository=repo, clock=lambda: RUN_AT)
    mismatched = ExternalSourceRecord(
        source="ski_api",
        external_id="x",
        payload={},
        content_hash=content_hash({}),
        snapshot_built_at=BUILT_AT,
    )

    with pytest.raises(ValidationError):
        service.upsert_records("openskidata", [mismatched], run_started_at=RUN_AT)


def test_ski_api_record_with_detail_stays_unchanged_when_list_entry_is_same() -> None:
    list_entry = {"slug": "grouse-mountain", "name": "Grouse Mountain"}
    detail = {"elevation": {"base_m": 274, "top_m": 1250}}
    existing = ResortSourceRecord(
        source="ski_api",
        external_id="grouse-mountain",
        payload={**list_entry, "detail": detail},
        content_hash=content_hash({**list_entry, "detail": detail}),
        fetched_at=RUN_AT,
        match_status="linked",
        match_method="auto",
    )
    repo = FakeRecordRepository([existing])
    service = ResortSourceRecordService(record_repository=repo, clock=lambda: RUN_AT)
    external = ExternalSourceRecord(
        source="ski_api",
        external_id="grouse-mountain",
        payload=dict(list_entry),
        content_hash=content_hash(list_entry),
        snapshot_built_at=None,
    )

    summary = service.upsert_records("ski_api", [external], run_started_at=RUN_AT)

    assert (summary.updated, summary.unchanged) == (0, 1)
    assert existing.payload["detail"] == detail


def test_ski_api_record_with_detail_preserves_detail_when_list_entry_changes() -> None:
    list_entry = {"slug": "grouse-mountain", "name": "Grouse Mountain"}
    changed_entry = {"slug": "grouse-mountain", "name": "Grouse Mountain Resort"}
    detail = {"elevation": {"base_m": 274, "top_m": 1250}}
    existing = ResortSourceRecord(
        source="ski_api",
        external_id="grouse-mountain",
        payload={**list_entry, "detail": detail},
        content_hash=content_hash({**list_entry, "detail": detail}),
        fetched_at=RUN_AT,
        match_status="linked",
        match_method="auto",
    )
    repo = FakeRecordRepository([existing])
    service = ResortSourceRecordService(record_repository=repo, clock=lambda: RUN_AT)
    external = ExternalSourceRecord(
        source="ski_api",
        external_id="grouse-mountain",
        payload=dict(changed_entry),
        content_hash=content_hash(changed_entry),
        snapshot_built_at=None,
    )

    summary = service.upsert_records("ski_api", [external], run_started_at=RUN_AT)

    assert (summary.updated, summary.unchanged) == (1, 0)
    assert existing.payload["name"] == "Grouse Mountain Resort"
    assert existing.payload["detail"] == detail
