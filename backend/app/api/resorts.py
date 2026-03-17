import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status
from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session
from sqlalchemy.sql.elements import ColumnElement

from app.core.dependencies import get_db
from app.models.resort import Resort
from app.schemas.resort import ResortListResponse
from app.schemas.resort import ResortPublic

router = APIRouter(prefix="/resorts", tags=["resorts"])


@router.get("", response_model=ResortListResponse)
def list_resorts(
    query: str | None = Query(default=None, max_length=120),
    region: str | None = Query(default=None, max_length=100),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    db: Session = Depends(get_db),
) -> ResortListResponse:
    search_query = query.strip() if query else None
    region_filter = region.strip() if region else None

    filters: list[ColumnElement[bool]] = []
    if search_query:
        filters.append(Resort.name.ilike(f"%{search_query}%"))
    if region_filter:
        filters.append(Resort.region.ilike(region_filter))

    total_stmt = select(func.count()).select_from(Resort)
    if filters:
        total_stmt = total_stmt.where(*filters)
    total = int(db.scalar(total_stmt) or 0)

    resorts_stmt = select(Resort).order_by(Resort.name.asc())
    if filters:
        resorts_stmt = resorts_stmt.where(*filters)

    resorts: list[Resort] = list(
        db.scalars(resorts_stmt.offset((page - 1) * page_size).limit(page_size)).all()
    )

    return ResortListResponse(
        items=[ResortPublic.model_validate(resort) for resort in resorts],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get("/{resort_id}", response_model=ResortPublic)
def get_resort(resort_id: uuid.UUID, db: Session = Depends(get_db)) -> ResortPublic:
    resort = db.scalar(select(Resort).where(Resort.id == resort_id))
    if resort is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Resort not found.",
        )
    return ResortPublic.model_validate(resort)
