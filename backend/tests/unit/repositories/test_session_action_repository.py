from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import uuid

from sqlalchemy.orm import Session

from app.models.ride_session import RideSession
from app.models.ride_session_action import RideSessionAction
from app.repositories.session_action_repository import SessionActionRepository


def _build_action(
    session_id: uuid.UUID,
    sequence_index: int,
    action_type: str = "run",
    started_at: datetime | None = None,
) -> RideSessionAction:
    start = started_at or datetime(2026, 4, 19, 9, 0, tzinfo=UTC)
    return RideSessionAction(
        session_id=session_id,
        action_type=action_type,
        sequence_index=sequence_index,
        started_at=start,
        ended_at=start + timedelta(minutes=5),
        duration_s=300.0,
        distance_m=900.0,
        avg_speed_mps=3.0,
        max_speed_mps=5.0,
        source="live_analyzer",
    )


def test_add_persists_single_action(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionActionRepository(db)

    repo.add(_build_action(ride_session.id, sequence_index=1))
    repo.commit()

    rows = repo.list_by_session(ride_session.id)
    assert len(rows) == 1
    assert rows[0].action_type == "run"
    assert rows[0].sequence_index == 1


def test_add_batch_persists_in_started_at_order(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionActionRepository(db)

    base = datetime(2026, 4, 19, 10, 0, tzinfo=UTC)
    repo.add_batch(
        [
            _build_action(
                ride_session.id,
                sequence_index=2,
                started_at=base + timedelta(minutes=10),
            ),
            _build_action(
                ride_session.id,
                sequence_index=1,
                started_at=base,
            ),
        ]
    )
    repo.commit()

    rows = repo.list_by_session(ride_session.id)
    assert [row.sequence_index for row in rows] == [1, 2]


def test_list_by_session_isolates_other_sessions(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    session_a = create_ride_session()
    session_b = create_ride_session()
    repo = SessionActionRepository(db)

    repo.add(_build_action(session_a.id, sequence_index=1))
    repo.add(_build_action(session_b.id, sequence_index=1, action_type="lift"))
    repo.commit()

    a_rows = repo.list_by_session(session_a.id)
    b_rows = repo.list_by_session(session_b.id)
    assert len(a_rows) == 1 and a_rows[0].action_type == "run"
    assert len(b_rows) == 1 and b_rows[0].action_type == "lift"


def test_delete_by_session_returns_rowcount_and_clears_rows(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = SessionActionRepository(db)
    repo.add_batch(
        [
            _build_action(ride_session.id, sequence_index=1),
            _build_action(ride_session.id, sequence_index=2, action_type="lift"),
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
    repo = SessionActionRepository(db)

    deleted = repo.delete_by_session(ride_session.id)
    repo.commit()

    assert deleted == 0
