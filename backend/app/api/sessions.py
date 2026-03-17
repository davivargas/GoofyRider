import uuid
from datetime import UTC
from datetime import datetime

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status
from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.dependencies import get_current_user
from app.core.dependencies import get_db
from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.session_point import SessionPoint
from app.models.user import User
from app.schemas.session import RideSessionPublic
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionListResponse
from app.schemas.session import SessionPointsBatchRequest
from app.schemas.session import SessionPointsBatchResponse

router = APIRouter(tags=["sessions"])


@router.post("/sessions", response_model=RideSessionPublic, status_code=status.HTTP_201_CREATED)
def create_session(
    payload: SessionCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RideSessionPublic:
    if payload.resort_id is not None:
        resort = db.scalar(select(Resort).where(Resort.id == payload.resort_id))
        if resort is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Resort not found.",
            )

    started_at = payload.started_at or datetime.now(UTC)
    ride_session = RideSession(
        user_id=current_user.id,
        resort_id=payload.resort_id,
        started_at=started_at,
        status=RideSessionStatus.DRAFT,
    )
    db.add(ride_session)
    db.commit()
    db.refresh(ride_session)
    return RideSessionPublic.model_validate(ride_session)


@router.post("/sessions/{session_id}/points:batch", response_model=SessionPointsBatchResponse)
def upload_session_points_batch(
    session_id: uuid.UUID,
    payload: SessionPointsBatchRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SessionPointsBatchResponse:
    ride_session = _get_owned_session(
        session_id=session_id,
        user_id=current_user.id,
        db=db,
    )
    if ride_session.status != RideSessionStatus.DRAFT:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Points can only be uploaded to draft sessions.",
        )

    points = [
        SessionPoint(
            session_id=ride_session.id,
            t_offset_ms=point.t_offset_ms,
            latitude=point.latitude,
            longitude=point.longitude,
            accuracy_m=point.accuracy_m,
            altitude_m=point.altitude_m,
            speed_mps=point.speed_mps,
            heading_deg=point.heading_deg,
        )
        for point in payload.points
    ]
    db.add_all(points)
    db.commit()

    return SessionPointsBatchResponse(
        session_id=ride_session.id,
        inserted_count=len(points),
    )


@router.post("/sessions/{session_id}/complete", response_model=RideSessionPublic)
def complete_session(
    session_id: uuid.UUID,
    payload: SessionCompleteRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RideSessionPublic:
    ride_session = _get_owned_session(
        session_id=session_id,
        user_id=current_user.id,
        db=db,
    )
    if ride_session.status != RideSessionStatus.DRAFT:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Only draft sessions can be completed.",
        )

    ended_at = payload.ended_at or datetime.now(UTC)
    if ended_at < ride_session.started_at:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="ended_at cannot be earlier than started_at.",
        )

    duration_s = payload.duration_s
    if duration_s is None:
        duration_s = int((ended_at - ride_session.started_at).total_seconds())

    if duration_s < 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="duration_s must be non-negative.",
        )

    ride_session.ended_at = ended_at
    ride_session.duration_s = duration_s
    ride_session.distance_m = payload.distance_m
    ride_session.max_speed_mps = payload.max_speed_mps
    ride_session.avg_speed_mps = payload.avg_speed_mps
    ride_session.elevation_gain_m = payload.elevation_gain_m
    ride_session.elevation_loss_m = payload.elevation_loss_m
    ride_session.status = RideSessionStatus.COMPLETED

    db.commit()
    db.refresh(ride_session)
    return RideSessionPublic.model_validate(ride_session)


@router.get("/users/me/sessions", response_model=SessionListResponse)
def list_user_sessions(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SessionListResponse:
    total = int(
        db.scalar(
            select(func.count())
            .select_from(RideSession)
            .where(RideSession.user_id == current_user.id)
        )
        or 0
    )

    stmt = (
        select(RideSession)
        .where(RideSession.user_id == current_user.id)
        .order_by(RideSession.started_at.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    sessions: list[RideSession] = list(db.scalars(stmt).all())

    return SessionListResponse(
        items=[RideSessionPublic.model_validate(session) for session in sessions],
        page=page,
        page_size=page_size,
        total=total,
    )


def _get_owned_session(session_id: uuid.UUID, user_id: uuid.UUID, db: Session) -> RideSession:
    ride_session = db.scalar(
        select(RideSession).where(
            RideSession.id == session_id,
            RideSession.user_id == user_id,
        )
    )
    if ride_session is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Session not found.",
        )
    return ride_session
