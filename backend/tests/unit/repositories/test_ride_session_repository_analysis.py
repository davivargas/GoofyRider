from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import uuid

from sqlalchemy.orm import Session

from app.models.ride_session import RideSession
from app.models.ride_session_action import RideSessionAction
from app.models.ride_session_override import RideSessionOverride
from app.repositories.ride_session_repository import RideSessionRepository


def _action(
    session_id: uuid.UUID,
    sequence_index: int,
    *,
    action_type: str = "run",
    started_at: datetime | None = None,
) -> RideSessionAction:
    start = started_at or datetime(2026, 4, 19, 9, 0, tzinfo=UTC)
    return RideSessionAction(
        session_id=session_id,
        action_type=action_type,
        sequence_index=sequence_index,
        started_at=start,
        ended_at=start + timedelta(minutes=4),
        duration_s=240.0,
        distance_m=720.0,
        avg_speed_mps=3.0,
        max_speed_mps=4.5,
        source="live_analyzer",
    )


def _override(
    session_id: uuid.UUID,
    started_at: datetime,
    *,
    motion_state: str = "ignore",
    created_by: str = "user",
) -> RideSessionOverride:
    return RideSessionOverride(
        session_id=session_id,
        started_at=started_at,
        ended_at=started_at + timedelta(seconds=20),
        motion_state=motion_state,
        created_by=created_by,
    )


def test_update_analysis_result_writes_summary_actions_and_overrides(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = RideSessionRepository(db)

    summary = {
        "total_duration_s": 1500.0,
        "descent_duration_s": 600.0,
        "descent_distance_m": 4800.0,
        "descent_vertical_m": 320.0,
        "lift_duration_s": 700.0,
        "lift_distance_m": 1200.0,
        "lift_vertical_m": 280.0,
        "avg_descent_speed_mps": 8.0,
        "max_speed_mps": 12.45,
        "peak_altitude_m": 1850.0,
    }
    actions = [
        _action(ride_session.id, 1, action_type="run"),
        _action(
            ride_session.id,
            1,
            action_type="lift",
            started_at=datetime(2026, 4, 19, 9, 10, tzinfo=UTC),
        ),
    ]
    overrides = [
        _override(
            ride_session.id,
            datetime(2026, 4, 19, 9, 5, tzinfo=UTC),
            created_by="importer",
        ),
    ]

    returned = repo.update_analysis_result(
        ride_session.id,
        summary_fields=summary,
        actions=actions,
        overrides=overrides,
        version="analyzer@1",
    )
    repo.commit()

    assert returned is not None
    assert returned.id == ride_session.id

    db.expire_all()
    fresh = db.get(RideSession, ride_session.id)
    assert fresh is not None
    assert fresh.total_duration_s == 1500.0
    assert fresh.descent_distance_m == 4800.0
    assert fresh.max_speed_mps == 12.45
    assert fresh.processed_by_version == "analyzer@1"
    assert fresh.processed_at is not None

    assert len(fresh.actions) == 2
    assert {action.action_type for action in fresh.actions} == {"run", "lift"}
    assert len(fresh.overrides) == 1
    assert fresh.overrides[0].created_by == "importer"


def test_update_analysis_result_replaces_prior_actions_and_overrides(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = RideSessionRepository(db)

    repo.update_analysis_result(
        ride_session.id,
        summary_fields={"total_duration_s": 100.0},
        actions=[_action(ride_session.id, 1)],
        overrides=[_override(ride_session.id, datetime(2026, 4, 19, 9, 0, tzinfo=UTC))],
        version="analyzer@1",
    )
    repo.commit()

    repo.update_analysis_result(
        ride_session.id,
        summary_fields={"total_duration_s": 200.0},
        actions=[
            _action(ride_session.id, 1, action_type="lift"),
            _action(
                ride_session.id,
                2,
                action_type="lift",
                started_at=datetime(2026, 4, 19, 9, 5, tzinfo=UTC),
            ),
        ],
        overrides=[],
        version="analyzer@2",
    )
    repo.commit()

    db.expire_all()
    fresh = db.get(RideSession, ride_session.id)
    assert fresh is not None
    assert fresh.total_duration_s == 200.0
    assert fresh.processed_by_version == "analyzer@2"
    assert [action.sequence_index for action in fresh.actions] == [1, 2]
    assert all(action.action_type == "lift" for action in fresh.actions)
    assert fresh.overrides == []


def test_update_analysis_result_returns_none_for_missing_session(
    db: Session,
) -> None:
    repo = RideSessionRepository(db)

    result = repo.update_analysis_result(
        uuid.uuid4(),
        summary_fields={"total_duration_s": 1.0},
        actions=[],
        overrides=[],
        version="analyzer@1",
    )

    assert result is None


def test_clear_analysis_removes_actions_overrides_and_processed_metadata(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = RideSessionRepository(db)

    repo.update_analysis_result(
        ride_session.id,
        summary_fields={"total_duration_s": 500.0},
        actions=[_action(ride_session.id, 1)],
        overrides=[_override(ride_session.id, datetime(2026, 4, 19, 9, 0, tzinfo=UTC))],
        version="analyzer@1",
    )
    repo.commit()

    cleared = repo.clear_analysis(ride_session.id)
    repo.commit()

    assert cleared is not None
    db.expire_all()
    fresh = db.get(RideSession, ride_session.id)
    assert fresh is not None
    assert fresh.actions == []
    assert fresh.overrides == []
    assert fresh.processed_by_version is None
    assert fresh.processed_at is None


def test_clear_analysis_returns_none_for_missing_session(db: Session) -> None:
    repo = RideSessionRepository(db)
    assert repo.clear_analysis(uuid.uuid4()) is None


def test_get_detail_with_actions_returns_session_with_eager_collections(
    db: Session,
    create_ride_session: Callable[..., RideSession],
) -> None:
    ride_session = create_ride_session()
    repo = RideSessionRepository(db)
    repo.update_analysis_result(
        ride_session.id,
        summary_fields={"total_duration_s": 900.0},
        actions=[
            _action(
                ride_session.id,
                1,
                action_type="run",
                started_at=datetime(2026, 4, 19, 9, 0, tzinfo=UTC),
            ),
            _action(
                ride_session.id,
                1,
                action_type="lift",
                started_at=datetime(2026, 4, 19, 9, 10, tzinfo=UTC),
            ),
        ],
        overrides=[
            _override(ride_session.id, datetime(2026, 4, 19, 9, 5, tzinfo=UTC)),
        ],
        version="analyzer@1",
    )
    repo.commit()

    detail = repo.get_detail_with_actions(ride_session.id)

    assert detail is not None
    assert detail.id == ride_session.id
    assert [action.action_type for action in detail.actions] == ["run", "lift"]
    assert len(detail.overrides) == 1


def test_get_detail_with_actions_returns_none_for_missing_session(db: Session) -> None:
    repo = RideSessionRepository(db)
    assert repo.get_detail_with_actions(uuid.uuid4()) is None
