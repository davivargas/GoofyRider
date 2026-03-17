import uuid
from collections.abc import Callable
from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.core.dependencies import get_db
from app.main import app
from app.models.resort import Resort

TABLES_TO_TRUNCATE = [
    "session_points",
    "weather_cache",
    "ride_sessions",
    "favorite_resorts",
    "resorts",
    "users",
]


@pytest.fixture
def db() -> Generator[Session, None, None]:
    session = SessionLocal()
    try:
        yield session
    finally:
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
        session.close()


@pytest.fixture
def client(db: Session) -> Generator[TestClient, None, None]:
    def override_get_db() -> Generator[Session, None, None]:
        yield db

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as test_client:
            yield test_client
    finally:
        app.dependency_overrides.clear()


@pytest.fixture
def create_resort(db: Session) -> Callable[..., Resort]:
    def _create_resort(
        name: str = "Whistler Blackcomb",
        country: str = "Canada",
        region: str = "British Columbia",
    ) -> Resort:
        resort = Resort(
            name=name,
            country=country,
            region=region,
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
def register_user(client: TestClient) -> Callable[..., dict[str, str]]:
    def _register_user(password: str = "strongpass123") -> dict[str, str]:
        email = f"qa_{uuid.uuid4().hex[:10]}@example.com"
        payload = {
            "email": email,
            "password": password,
            "display_name": "QA Rider",
        }
        response = client.post("/v1/auth/register", json=payload)
        assert response.status_code == 201

        token_pair = response.json()
        return {
            "email": email,
            "password": password,
            "access_token": token_pair["access_token"],
            "refresh_token": token_pair["refresh_token"],
        }

    return _register_user
