from typing import Any
import uuid

from sqlalchemy import delete
from sqlalchemy import select

from app.models.resort_field_override import ResortFieldOverride
from app.repositories.base import SqlAlchemyRepository


class ResortFieldOverrideRepository(SqlAlchemyRepository):
    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortFieldOverride]:
        stmt = (
            select(ResortFieldOverride)
            .where(ResortFieldOverride.resort_id == resort_id)
            .order_by(ResortFieldOverride.field.asc())
        )
        return list(self._db.scalars(stmt).all())

    def upsert(
        self, resort_id: uuid.UUID, field: str, value: Any, note: str | None
    ) -> ResortFieldOverride:
        existing = self._db.scalar(
            select(ResortFieldOverride).where(
                ResortFieldOverride.resort_id == resort_id, ResortFieldOverride.field == field
            )
        )
        if existing is None:
            existing = ResortFieldOverride(resort_id=resort_id, field=field, value=value, note=note)
            self._db.add(existing)
        else:
            existing.value = value
            existing.note = note
        self._db.flush()
        return existing

    def delete(self, resort_id: uuid.UUID, field: str) -> int:
        result = self._db.execute(
            delete(ResortFieldOverride).where(
                ResortFieldOverride.resort_id == resort_id, ResortFieldOverride.field == field
            )
        )
        rowcount = getattr(result, "rowcount", None)
        return int(rowcount or 0)
