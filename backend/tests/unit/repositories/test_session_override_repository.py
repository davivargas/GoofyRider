from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import uuid

from sqlalchemy.orm import Session

from app.models.ride_session import RideSession
from app.models.ride_session_override import RideSessionOverride
from app.repositories.session_override_repository import SessionOverrideRepository


def _build_override(
    session_id: uuid.UUID,
    started_at: datetime,
    motion_state: str = "ignore",
    created_by: str = "user",
) -> RideSessionOverride:
    return RideSessionOverride(
        session_id=session_id,
        started_at=started_at,
        ended_at=started_at + timedelta(seconds=30),
        motion_state=motion_state,
        created_by=created_by,
    )


def test_add_persists_single_override(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionOverrideRepository(db)

    repo.add(
        _build_override(ride_session.id, datetime(2026, 4, 19, 9, 0, tzinfo=UTC))
    )
    repo.commit()

    rows = repo.list_by_session(ride_session.id)
    assert len(rows) == 1
    assert rows[0].motion_state == "ignore"
    assert rows[0].created_by == "user"


def test_add_batch_persists_in_started_at_order(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionOverrideRepository(db)

    base = datetime(2026, 4, 19, 9, 0, tzinfo=UTC)
    repo.add_batch(
        [
            _build_override(
                ride_session.id,
                started_at=base + timedelta(minutes=5),
                motion_state="run",
                created_by="importer",
            ),
            _build_override(
                ride_session.id,
                started_at=base,
                motion_state="lift",
                created_by="importer",
            ),
        ]
    )
    repo.commit()

    rows = repo.list_by_session(ride_session.id)
    assert [row.motion_state for row in rows] == ["lift", "run"]


def test_list_by_session_isolates_other_sessions(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    session_a = create_ride_session()
    session_b = create_ride_session()
    repo = SessionOverrideRepository(db)
    base = datetime(2026, 4, 19, 9, 0, tzinfo=UTC)

    repo.add(_build_override(session_a.id, base))
    repo.add(_build_override(session_b.id, base, motion_state="lift"))
    repo.commit()

    a_rows = repo.list_by_session(session_a.id)
    b_rows = repo.list_by_session(session_b.id)
    assert len(a_rows) == 1 and a_rows[0].motion_state == "ignore"
    assert len(b_rows) == 1 and b_rows[0].motion_state == "lift"


def test_delete_by_session_returns_rowcount_and_clears_rows(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionOverrideRepository(db)
    base = datetime(2026, 4, 19, 9, 0, tzinfo=UTC)
    repo.add_batch(
        [
            _build_override(ride_session.id, base),
            _build_override(ride_session.id, base + timedelta(minutes=1)),
        ]
    )
    repo.commit()

    deleted = repo.delete_by_session(ride_session.id)
    repo.commit()

    assert deleted == 2
    assert repo.list_by_session(ride_session.id) == []


def test_delete_by_session_returns_zero_when_no_rows(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionOverrideRepository(db)

    deleted = repo.delete_by_session(ride_session.id)
    repo.commit()

    assert deleted == 0
