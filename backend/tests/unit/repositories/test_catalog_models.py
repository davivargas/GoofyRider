from collections.abc import Callable
from datetime import UTC
from datetime import datetime

import pytest
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.resort_field_override import ResortFieldOverride
from app.models.resort_lift import ResortLift
from app.models.resort_source_record import ResortSourceRecord

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def test_resort_defaults_new_catalog_columns(create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()

    assert resort.name_aliases == []
    assert resort.field_provenance == {}
    assert resort.boundary is None
    assert resort.last_merged_at is None
    assert not hasattr(resort, "external_source")


def test_source_record_unique_per_source_and_external_id(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    db.add(_record(resort, external_id="abc"))
    db.commit()
    db.add(_record(resort, external_id="abc"))

    with pytest.raises(IntegrityError):
        db.commit()
    db.rollback()


def test_source_record_rejects_unknown_status(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    db.add(_record(resort, external_id="x", match_status="maybe"))

    with pytest.raises(IntegrityError):
        db.commit()
    db.rollback()


def test_override_unique_per_resort_and_field(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    db.add(ResortFieldOverride(resort_id=resort.id, field="city", value="Whistler"))
    db.commit()
    db.add(ResortFieldOverride(resort_id=resort.id, field="city", value="Other"))

    with pytest.raises(IntegrityError):
        db.commit()
    db.rollback()


def test_lift_defaults_to_overpass_source(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    lift = ResortLift(resort_id=resort.id, name="Chair", external_track_id="osm:way:1")
    db.add(lift)
    db.commit()
    db.refresh(lift)

    assert lift.source == "overpass"
    assert lift.status is None
    assert lift.source_record_id is None


def _record(
    resort: Resort, *, external_id: str, match_status: str = "linked"
) -> ResortSourceRecord:
    return ResortSourceRecord(
        source="openskidata",
        external_id=external_id,
        payload={"id": external_id},
        content_hash="0" * 64,
        fetched_at=NOW,
        resort_id=resort.id,
        match_status=match_status,
        match_method="primary" if match_status == "linked" else None,
    )
