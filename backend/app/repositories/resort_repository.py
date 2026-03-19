import uuid

from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session
from sqlalchemy.sql.elements import ColumnElement

from app.models.resort import Resort
from app.repositories.base import SqlAlchemyRepository


class ResortRepository(SqlAlchemyRepository):
    def __init__(self, db: Session) -> None:
        super().__init__(db)

    def add(self, resort: Resort) -> None:
        self._db.add(resort)

    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        return self._db.scalar(select(Resort).where(Resort.id == resort_id))

    def get_by_external_ref(
        self,
        external_source: str,
        external_id: str,
    ) -> Resort | None:
        stmt = select(Resort).where(
            Resort.external_source == external_source,
            Resort.external_id == external_id,
        )
        return self._db.scalar(stmt)

    def get_by_name_country_region(
        self,
        name: str,
        country: str,
        region: str,
    ) -> Resort | None:
        stmt = select(Resort).where(
            func.lower(Resort.name) == name.lower(),
            func.lower(Resort.country) == country.lower(),
            func.lower(Resort.region) == region.lower(),
        )
        return self._db.scalar(stmt)

    def list_by_external_source(self, external_source: str) -> list[Resort]:
        stmt = select(Resort).where(Resort.external_source == external_source)
        return list(self._db.scalars(stmt).all())

    def count_filtered(self, query: str | None, region: str | None) -> int:
        stmt = select(func.count()).select_from(Resort).where(Resort.is_active.is_(True))
        filters = self._build_filters(query=query, region=region)
        if filters:
            stmt = stmt.where(*filters)
        return int(self._db.scalar(stmt) or 0)

    def list_filtered(
        self,
        query: str | None,
        region: str | None,
        page: int,
        page_size: int,
    ) -> list[Resort]:
        stmt = select(Resort).where(Resort.is_active.is_(True)).order_by(Resort.name.asc())
        filters = self._build_filters(query=query, region=region)
        if filters:
            stmt = stmt.where(*filters)
        stmt = stmt.offset((page - 1) * page_size).limit(page_size)
        return list(self._db.scalars(stmt).all())

    def _build_filters(
        self,
        query: str | None,
        region: str | None,
    ) -> list[ColumnElement[bool]]:
        filters: list[ColumnElement[bool]] = []
        if query:
            filters.append(Resort.name.ilike(f"%{query}%"))
        if region:
            filters.append(Resort.region.ilike(region))
        return filters
