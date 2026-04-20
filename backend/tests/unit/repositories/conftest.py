from collections.abc import Callable
from collections.abc import Generator
from datetime import UTC
from datetime import datetime
import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import get_session_local
from app.core.database_safety import assert_safe_test_database_name
from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.user import User

TABLES_TO_TRUNCATE = [
    "ride_session_actions",
    "ride_session_overrides",
    "session_points",
    "ride_session_points",
    "weather_cache",
    "ride_sessions",
    "favorite_resorts",
    "resort_lifts",
    "resorts",
    "users",
]


@pytest.fixture
def db() -> Generator[Session, None, None]:
    session = get_session_local()()
    try:
        _truncate_known_tables(session)
        yield session
    finally:
        session.rollback()
        _truncate_known_tables(session)
        session.close()


@pytest.fixture
def create_user(db: Session) -> Callable[..., User]:
    def _create_user(email: str | None = None) -> User:
        user = User(
            email=email or f"repo_{uuid.uuid4().hex[:10]}@example.com",
            password_hash="hash",
            display_name="Repo Tester",
        )
        db.add(user)
        db.commit()
        db.refresh(user)
        return user

    return _create_user


@pytest.fixture
def create_resort(db: Session) -> Callable[..., Resort]:
    def _create_resort(name: str = "Whistler Blackcomb") -> Resort:
        resort = Resort(
            name=name,
            country="Canada",
            region="British Columbia",
            city="Test City",
            latitude=50.0,
            longitude=-122.0,
            elevation_base_m=700,
            elevation_top_m=2200,
        )
        db.add(resort)
        db.commit()
        db.refresh(resort)
        return resort

    return _create_resort


@pytest.fixture
def create_ride_session(db: Session, create_user: Callable[..., User]) -> Callable[..., RideSession]:
    def _create_ride_session(
        user: User | None = None,
        started_at: datetime | None = None,
    ) -> RideSession:
        owner = user or create_user()
        session_obj = RideSession(
            user_id=owner.id,
            started_at=started_at or datetime(2026, 4, 19, 9, 0, tzinfo=UTC),
            descent_distance_m=0.0,
            descent_duration_s=0.0,
            descent_vertical_m=0.0,
            lift_distance_m=0.0,
            lift_duration_s=0.0,
            lift_vertical_m=0.0,
            avg_descent_speed_mps=0.0,
            total_duration_s=0.0,
        )
        db.add(session_obj)
        db.commit()
        db.refresh(session_obj)
        return session_obj

    return _create_ride_session


def _truncate_known_tables(session: Session) -> None:
    session.rollback()
    database_name = session.execute(text("SELECT current_database()")).scalar_one()
    assert_safe_test_database_name(database_name)

    existing_tables = set(
        session.execute(
            text(
                """
                SELECT tablename
                FROM pg_tables
                WHERE schemaname = 'public'
                """
            )
        ).scalars()
    )

    for table in TABLES_TO_TRUNCATE:
        if table in existing_tables:
            session.execute(text(f"TRUNCATE TABLE {table} RESTART IDENTITY CASCADE"))

    session.commit()
