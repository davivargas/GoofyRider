import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Response
from fastapi import status
from sqlalchemy import delete
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.dependencies import get_current_user
from app.core.dependencies import get_db
from app.models.favorite_resort import FavoriteResort
from app.models.resort import Resort
from app.models.user import User
from app.schemas.resort import ResortPublic

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me/favorites", response_model=list[ResortPublic])
def list_favorite_resorts(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ResortPublic]:
    stmt = (
        select(Resort)
        .join(FavoriteResort, FavoriteResort.resort_id == Resort.id)
        .where(FavoriteResort.user_id == current_user.id)
        .order_by(Resort.name.asc())
    )
    resorts: list[Resort] = list(db.scalars(stmt).all())
    return [ResortPublic.model_validate(resort) for resort in resorts]


@router.post(
    "/me/favorites/{resort_id}",
    response_model=ResortPublic,
    status_code=status.HTTP_201_CREATED,
)
def add_favorite_resort(
    resort_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ResortPublic:
    resort = db.scalar(select(Resort).where(Resort.id == resort_id))
    if resort is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Resort not found.",
        )

    existing = db.scalar(
        select(FavoriteResort).where(
            FavoriteResort.user_id == current_user.id,
            FavoriteResort.resort_id == resort_id,
        )
    )
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Resort is already in favorites.",
        )

    db.add(FavoriteResort(user_id=current_user.id, resort_id=resort_id))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Resort is already in favorites.",
        ) from None

    return ResortPublic.model_validate(resort)


@router.delete("/me/favorites/{resort_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_favorite_resort(
    resort_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    existing_favorite = db.scalar(
        select(FavoriteResort).where(
            FavoriteResort.user_id == current_user.id,
            FavoriteResort.resort_id == resort_id,
        )
    )

    if existing_favorite is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Favorite resort not found.",
        )

    db.execute(
        delete(FavoriteResort).where(
            FavoriteResort.user_id == current_user.id,
            FavoriteResort.resort_id == resort_id,
        )
    )
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
