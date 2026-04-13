from collections.abc import Generator

from sqlalchemy.orm import Session

from app.core.database import get_session_local


def get_db() -> Generator[Session, None, None]:
    db = get_session_local()()
    try:
        yield db
    finally:
        db.close()
