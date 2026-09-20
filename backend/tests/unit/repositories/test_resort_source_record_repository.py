from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta

from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.resort_source_record import ResortSourceRecord
from app.repositories.resort_repository import ResortRepository
from app.repositories.resort_source_record_repository import ResortSourceRecordRepository

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def _record(
    *,
    source: str = "openskidata",
    external_id: str,
    resort: Resort | None = None,
    match_status: str = "linked",
    match_method: str | None = "primary",
) -> ResortSourceRecord:
    return ResortSourceRecord(
        source=source,
        external_id=external_id,
        payload={"id": external_id},
        content_hash="a" * 64,
        fetched_at=NOW,
        resort_id=resort.id if resort else None,
        match_status=match_status,
        match_method=match_method if match_status == "linked" else None,
    )


def test_get_by_source_and_external_id(db: Session, create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()
    repo = ResortSourceRecordRepository(db)
    repo.add(_record(external_id="area-1", resort=resort))
    repo.commit()

    found = repo.get_by_source_and_external_id("openskidata", "area-1")
    assert found is not None and found.resort_id == resort.id
    assert repo.get_by_source_and_external_id("ski_api", "area-1") is None


def test_list_pending_and_unlinked(db: Session, create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()
    repo = ResortSourceRecordRepository(db)
    repo.add(_record(external_id="b", match_status="pending_review", match_method=None))
    repo.add(_record(external_id="a", match_status="pending_review", match_method=None))
    repo.add(_record(external_id="c", resort=resort))
    repo.add(_record(source="ski_api", external_id="d", match_status="pending_review"))
    repo.commit()

    assert [r.external_id for r in repo.list_pending_review()] == ["a", "b", "d"]
    assert [r.external_id for r in repo.list_pending_review("ski_api")] == ["d"]
    assert [r.external_id for r in repo.list_unlinked("openskidata")] == ["a", "b"]


def test_mark_missing_except_sets_only_unseen_and_unset(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortSourceRecordRepository(db)
    earlier = NOW - timedelta(days=3)
    already_missing = _record(external_id="old", resort=resort)
    already_missing.missing_since = earlier
    repo.add(already_missing)
    repo.add(_record(external_id="seen", resort=resort))
    repo.add(_record(external_id="gone", resort=resort))
    repo.add(_record(source="ski_api", external_id="other-source", resort=resort))
    repo.commit()

    count = repo.mark_missing_except("openskidata", {"seen"}, NOW)
    repo.commit()

    assert count == 1
    by_id = {r.external_id: r for r in repo.list_by_source("openskidata")}
    assert by_id["gone"].missing_since == NOW
    assert by_id["old"].missing_since == earlier
    assert by_id["seen"].missing_since is None
    other = repo.get_by_source_and_external_id("ski_api", "other-source")
    assert other is not None and other.missing_since is None


def test_mark_missing_except_with_no_seen_ids_marks_nothing(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortSourceRecordRepository(db)
    repo.add(_record(external_id="a", resort=resort))
    repo.add(_record(external_id="b", resort=resort))
    repo.commit()

    # An empty snapshot means the fetch failed, not that the source emptied out.
    count = repo.mark_missing_except("openskidata", set(), NOW)
    repo.commit()

    assert count == 0
    assert all(r.missing_since is None for r in repo.list_by_source("openskidata"))


def test_list_legacy_with_candidates(db: Session, create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()
    repo = ResortSourceRecordRepository(db)
    with_candidates = _record(
        source="ski_api", external_id="big-white", resort=resort, match_method="legacy"
    )
    with_candidates.match_candidates = [
        {"resort_id": "r-1", "name": "Big White", "external_id": "osd-big-white"}
    ]
    repo.add(with_candidates)
    repo.add(
        _record(source="ski_api", external_id="a-legacy", resort=resort, match_method="legacy")
    )
    repo.add(_record(external_id="primary", resort=resort))
    repo.commit()

    found = repo.list_legacy_with_candidates()

    assert [r.external_id for r in found] == ["big-white"]
    assert found[0].match_candidates is not None


def test_resort_repository_lists_without_source_and_stale(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    linked = create_resort(name="Linked")
    legacy = create_resort(name="Legacy")
    merged = create_resort(name="Merged")
    merged.last_merged_at = datetime.now(UTC) + timedelta(hours=1)
    records = ResortSourceRecordRepository(db)
    records.add(_record(external_id="l", resort=linked))
    records.add(_record(source="ski_api", external_id="x", resort=legacy, match_method="legacy"))
    records.add(_record(external_id="m", resort=merged))
    records.commit()

    resorts = ResortRepository(db)
    assert [r.name for r in resorts.list_without_source("openskidata")] == ["Legacy"]
    stale_names = sorted(r.name for r in resorts.list_stale_for_merge())
    assert stale_names == ["Legacy", "Linked"]
    assert [r.id for r in resorts.list_all_for_matching()] == sorted(
        [linked.id, legacy.id, merged.id]
    )
