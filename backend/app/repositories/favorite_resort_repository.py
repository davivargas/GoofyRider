import uuid

from sqlalchemy import delete
from sqlalchemy import select

from app.models.favorite_resort import FavoriteResort
from app.models.resort import Resort
from app.repositories.base import SqlAlchemyRepository


class FavoriteResortRepository(SqlAlchemyRepository):
    def list_by_user_id(self, user_id: uuid.UUID) -> list[Resort]:
        stmt = (
            select(Resort)
            .join(FavoriteResort, FavoriteResort.resort_id == Resort.id)
            .where(FavoriteResort.user_id == user_id)
            .order_by(Resort.name.asc())
        )
        return list(self._db.scalars(stmt).all())

    def exists(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> bool:
        stmt = select(FavoriteResort).where(
            FavoriteResort.user_id == user_id,
            FavoriteResort.resort_id == resort_id,
        )
        return self._db.scalar(stmt) is not None

    def add(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> None:
        self._db.add(FavoriteResort(user_id=user_id, resort_id=resort_id))

    def delete(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> int:
        result = self._db.execute(
            delete(FavoriteResort).where(
                FavoriteResort.user_id == user_id,
                FavoriteResort.resort_id == resort_id,
            )
        )
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)
