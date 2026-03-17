import uuid
from typing import Protocol

from app.models.resort import Resort
from app.services.exceptions import NotFoundError


class ResortRepositoryProtocol(Protocol):
    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        ...

    def count_filtered(self, query: str | None, region: str | None) -> int:
        ...

    def list_filtered(
        self,
        query: str | None,
        region: str | None,
        page: int,
        page_size: int,
    ) -> list[Resort]:
        ...


class ResortService:
    def __init__(self, resort_repository: ResortRepositoryProtocol) -> None:
        self._resort_repository = resort_repository

    def list_resorts(
        self,
        query: str | None,
        region: str | None,
        page: int,
        page_size: int,
    ) -> tuple[list[Resort], int]:
        search_query = query.strip() if query else None
        region_filter = region.strip() if region else None
        total = self._resort_repository.count_filtered(search_query, region_filter)
        resorts = self._resort_repository.list_filtered(search_query, region_filter, page, page_size)
        return resorts, total

    def get_resort(self, resort_id: uuid.UUID) -> Resort:
        resort = self._resort_repository.get_by_id(resort_id)
        if resort is None:
            raise NotFoundError("Resort not found.")
        return resort
