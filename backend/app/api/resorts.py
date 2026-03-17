import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status

from app.core.dependencies import get_resort_service
from app.schemas.resort import ResortListResponse
from app.schemas.resort import ResortPublic
from app.services.exceptions import NotFoundError
from app.services.resort_service import ResortService

router = APIRouter(prefix="/resorts", tags=["resorts"])


@router.get("", response_model=ResortListResponse)
def list_resorts(
    query: str | None = Query(default=None, max_length=120),
    region: str | None = Query(default=None, max_length=100),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    resort_service: ResortService = Depends(get_resort_service),
) -> ResortListResponse:
    resorts, total = resort_service.list_resorts(
        query=query,
        region=region,
        page=page,
        page_size=page_size,
    )
    return ResortListResponse(
        items=[ResortPublic.model_validate(resort) for resort in resorts],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get("/{resort_id}", response_model=ResortPublic)
def get_resort(
    resort_id: uuid.UUID,
    resort_service: ResortService = Depends(get_resort_service),
) -> ResortPublic:
    try:
        resort = resort_service.get_resort(resort_id=resort_id)
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc

    return ResortPublic.model_validate(resort)
