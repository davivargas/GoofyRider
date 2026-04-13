import logging
import uuid

from app.models.resort import Resort
from app.repositories.protocols import ResortRepositoryProtocol
from app.services.exceptions import NotFoundError

logger = logging.getLogger(__name__)


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
        return self._resort_repository.list_filtered_with_count(
            search_query, region_filter, page, page_size
        )

    def get_resort(self, resort_id: uuid.UUID) -> Resort:
        resort = self._resort_repository.get_by_id(resort_id)
        if resort is None:
            logger.warning("Resort not found: %s", resort_id)
            raise NotFoundError("Resort not found.")
        return resort
