import uuid

from sqlalchemy import select

from app.models.weather_cache import WeatherCache
from app.repositories.base import SqlAlchemyRepository


class WeatherCacheRepository(SqlAlchemyRepository):
    def get_by_resort_id(self, resort_id: uuid.UUID) -> WeatherCache | None:
        stmt = select(WeatherCache).where(WeatherCache.resort_id == resort_id)
        return self._db.scalar(stmt)

    def add(self, cache: WeatherCache) -> None:
        self._db.add(cache)
