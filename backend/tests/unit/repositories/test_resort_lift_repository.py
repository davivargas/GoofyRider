from collections.abc import Callable

from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.resort_lift import ResortLift
from app.repositories.resort_lift_repository import ResortLiftRepository


def _add_lift(
    db: Session,
    resort: Resort,
    name: str,
    *,
    lift_type: str | None = None,
    external_track_id: str | None = None,
) -> ResortLift:
    lift = ResortLift(
        resort_id=resort.id,
        name=name,
        lift_type=lift_type,
        external_track_id=external_track_id,
    )
    db.add(lift)
    db.commit()
    db.refresh(lift)
    return lift


def test_list_by_resort_returns_lifts_alphabetically(
    db: Session,
    create_resort: Callable[..., Resort],
) -> None:
    resort = create_resort()
    _add_lift(db, resort, "Peak Express", lift_type="chair")
    _add_lift(db, resort, "Big Red", lift_type="chair")
    _add_lift(db, resort, "Whistler Village Gondola", lift_type="gondola")

    repo = ResortLiftRepository(db)
    lifts = repo.list_by_resort(resort.id)

    assert [lift.name for lift in lifts] == [
        "Big Red",
        "Peak Express",
        "Whistler Village Gondola",
    ]


def test_list_by_resort_isolates_other_resorts(
    db: Session,
    create_resort: Callable[..., Resort],
) -> None:
    resort_a = create_resort(name="Resort A")
    resort_b = create_resort(name="Resort B")
    _add_lift(db, resort_a, "A Lift")
    _add_lift(db, resort_b, "B Lift")

    repo = ResortLiftRepository(db)
    a_lifts = repo.list_by_resort(resort_a.id)
    b_lifts = repo.list_by_resort(resort_b.id)

    assert [lift.name for lift in a_lifts] == ["A Lift"]
    assert [lift.name for lift in b_lifts] == ["B Lift"]


def test_match_track_id_returns_lift_when_present(
    db: Session,
    create_resort: Callable[..., Resort],
) -> None:
    resort = create_resort()
    target = _add_lift(
        db,
        resort,
        "Peak Express",
        lift_type="chair",
        external_track_id="slopes-track-123",
    )
    _add_lift(db, resort, "Decoy", external_track_id="slopes-track-999")

    repo = ResortLiftRepository(db)
    matched = repo.match_track_id("slopes-track-123")

    assert matched is not None
    assert matched.id == target.id


def test_match_track_id_returns_none_when_unknown(
    db: Session,
    create_resort: Callable[..., Resort],
) -> None:
    resort = create_resort()
    _add_lift(db, resort, "Peak Express", external_track_id="present")

    repo = ResortLiftRepository(db)

    assert repo.match_track_id("missing") is None


def test_upsert_by_external_track_id_inserts_then_updates(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    first = [
        ResortLift(
            resort_id=resort.id,
            name="Old Name",
            lift_type="chair",
            polyline="[[1,2],[3,4]]",
            external_track_id="osm:way:1",
        )
    ]
    assert repo.upsert_by_external_track_id(resort.id, first) == 1
    repo.commit()
    second = [
        ResortLift(
            resort_id=resort.id,
            name="New Name",
            lift_type="gondola",
            osm_aerialway="gondola",
            polyline="[[1,2],[3,5]]",
            external_track_id="osm:way:1",
        ),
        ResortLift(
            resort_id=resort.id,
            name="Other",
            lift_type="surface",
            polyline="[[0,0],[0,1]]",
            external_track_id="osm:way:2",
        ),
    ]
    assert repo.upsert_by_external_track_id(resort.id, second) == 2
    repo.commit()
    lifts = {lift.external_track_id: lift for lift in repo.list_by_resort(resort.id)}
    assert set(lifts) == {"osm:way:1", "osm:way:2"}
    assert lifts["osm:way:1"].name == "New Name"
    assert lifts["osm:way:1"].lift_type == "gondola"
    assert lifts["osm:way:1"].osm_aerialway == "gondola"


def test_upsert_by_external_track_id_skips_rows_with_no_track_id(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    rows = [
        ResortLift(
            resort_id=resort.id,
            name="No Track Id",
            lift_type="chair",
            polyline="[[1,2],[3,4]]",
            external_track_id=None,
        ),
        ResortLift(
            resort_id=resort.id,
            name="Has Track Id",
            lift_type="chair",
            polyline="[[1,2],[3,4]]",
            external_track_id="osm:way:3",
        ),
    ]

    assert repo.upsert_by_external_track_id(resort.id, rows) == 1
    repo.commit()

    lifts = repo.list_by_resort(resort.id)
    assert [lift.name for lift in lifts] == ["Has Track Id"]


def test_upsert_by_external_track_id_deduplicates_within_one_batch(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    rows = [
        ResortLift(
            resort_id=resort.id,
            name="First",
            lift_type="chair",
            polyline="[[1,2],[3,4]]",
            external_track_id="osm:way:dup",
        ),
        ResortLift(
            resort_id=resort.id,
            name="Second",
            lift_type="chair",
            polyline="[[1,2],[3,4]]",
            external_track_id="osm:way:dup",
        ),
    ]

    assert repo.upsert_by_external_track_id(resort.id, rows) == 2
    repo.commit()

    lifts = repo.list_by_resort(resort.id)
    assert [lift.name for lift in lifts] == ["Second"]


def test_delete_missing_for_resort_keeps_listed_tracks_and_other_sources(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    keep = _add_lift(db, resort, "Keep", external_track_id="osm:way:1")
    keep.source = "openskidata"
    gone = _add_lift(db, resort, "Gone", external_track_id="osm:way:2")
    gone.source = "openskidata"
    _add_lift(db, resort, "Legacy", external_track_id="osm:way:3")  # source overpass
    db.commit()

    repo = ResortLiftRepository(db)
    deleted = repo.delete_missing_for_resort(resort.id, {"osm:way:1"}, source="openskidata")
    repo.commit()

    assert deleted == 1
    assert sorted(lift.name for lift in repo.list_by_resort(resort.id)) == ["Keep", "Legacy"]


def test_delete_by_source_for_resort(db: Session, create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()
    _add_lift(db, resort, "Legacy A", external_track_id="osm:way:1")
    _add_lift(db, resort, "Legacy B", external_track_id="osm:way:2")

    repo = ResortLiftRepository(db)
    assert repo.delete_by_source_for_resort(resort.id, "overpass") == 2
    repo.commit()
    assert repo.list_by_resort(resort.id) == []


def test_upsert_copies_status_source_and_record_id(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    row = ResortLift(
        resort_id=resort.id,
        name="New",
        lift_type="chair",
        external_track_id="osm:way:9",
        status="operating",
        source="openskidata",
    )
    repo.upsert_by_external_track_id(resort.id, [row])
    row2 = ResortLift(
        resort_id=resort.id,
        name="Renamed",
        lift_type="chair",
        external_track_id="osm:way:9",
        status="disused",
        source="openskidata",
    )
    repo.upsert_by_external_track_id(resort.id, [row2])
    repo.commit()

    lifts = repo.list_by_resort(resort.id)
    assert len(lifts) == 1
    assert (lifts[0].name, lifts[0].status, lifts[0].source) == (
        "Renamed",
        "disused",
        "openskidata",
    )


def test_upsert_keeps_existing_source_when_row_has_none(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    first = ResortLift(
        resort_id=resort.id,
        name="Original",
        lift_type="chair",
        external_track_id="osm:way:42",
        source="openskidata",
    )
    repo.upsert_by_external_track_id(resort.id, [first])
    repo.commit()

    update_row = ResortLift(
        resort_id=resort.id,
        name="Updated",
        lift_type="chair",
        external_track_id="osm:way:42",
    )
    repo.upsert_by_external_track_id(resort.id, [update_row])
    repo.commit()

    lifts = repo.list_by_resort(resort.id)
    assert len(lifts) == 1
    assert (lifts[0].name, lifts[0].source) == ("Updated", "openskidata")
