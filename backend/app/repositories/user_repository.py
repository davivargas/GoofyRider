import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.user import User
from app.repositories.base import SqlAlchemyRepository


class UserRepository(SqlAlchemyRepository):
    def __init__(self, db: Session) -> None:
        super().__init__(db)

    def get_by_email(self, email: str) -> User | None:
        return self._db.scalar(select(User).where(User.email == email))

    def get_by_id(self, user_id: uuid.UUID) -> User | None:
        return self._db.scalar(select(User).where(User.id == user_id))

    def add(self, user: User) -> None:
        self._db.add(user)
