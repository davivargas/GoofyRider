import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status

from app.core.dependencies import get_current_user
from app.core.dependencies import get_session_service
from app.models.user import User
from app.schemas.session import RideSessionPublic
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionListResponse
from app.schemas.session import SessionPointPublic
from app.schemas.session import SessionPointsBatchRequest
from app.schemas.session import SessionPointsBatchResponse
from app.schemas.session import SessionPointsListResponse
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError
from app.services.session_service import SessionCompletionInput
from app.services.session_service import SessionCreateInput
from app.services.session_service import SessionPointInputData
from app.services.session_service import SessionService

router = APIRouter(tags=["sessions"])


@router.post("/sessions", response_model=RideSessionPublic, status_code=status.HTTP_201_CREATED)
def create_session(
    payload: SessionCreateRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    request = SessionCreateInput(
        user_id=current_user.id,
        resort_id=payload.resort_id,
        started_at=payload.started_at,
    )
    try:
        ride_session = session_service.create_session(request)
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc

    return RideSessionPublic.model_validate(ride_session)


@router.post("/sessions/{session_id}/points:batch", response_model=SessionPointsBatchResponse)
def upload_session_points_batch(
    session_id: uuid.UUID,
    payload: SessionPointsBatchRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionPointsBatchResponse:
    points = [
        SessionPointInputData(
            t_offset_ms=point.t_offset_ms,
            latitude=point.latitude,
            longitude=point.longitude,
            accuracy_m=point.accuracy_m,
            elapsed_realtime_ns=point.elapsed_realtime_ns,
            altitude_m=point.altitude_m,
            vertical_accuracy_m=point.vertical_accuracy_m,
            speed_mps=point.speed_mps,
            speed_accuracy_mps=point.speed_accuracy_mps,
            heading_deg=point.heading_deg,
            bearing_accuracy_deg=point.bearing_accuracy_deg,
            provider=point.provider,
            is_mocked=point.is_mocked,
            quality_class=point.quality_class,
            quality_score=point.quality_score,
            quality_reason=point.quality_reason,
            filtered_latitude=point.filtered_latitude,
            filtered_longitude=point.filtered_longitude,
            filtered_altitude_m=point.filtered_altitude_m,
            fused_speed_mps=point.fused_speed_mps,
            derived_speed_mps=point.derived_speed_mps,
            distance_delta_m=point.distance_delta_m,
            motion_state=point.motion_state,
        )
        for point in payload.points
    ]
    try:
        inserted_count = session_service.upload_points_batch(
            session_id=session_id,
            user_id=current_user.id,
            points=points,
        )
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except ConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc

    return SessionPointsBatchResponse(session_id=session_id, inserted_count=inserted_count)


@router.post("/sessions/{session_id}/complete", response_model=RideSessionPublic)
def complete_session(
    session_id: uuid.UUID,
    payload: SessionCompleteRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    completion = SessionCompletionInput(
        ended_at=payload.ended_at,
        duration_s=payload.duration_s,
        distance_m=payload.distance_m,
        max_speed_mps=payload.max_speed_mps,
        avg_speed_mps=payload.avg_speed_mps,
        elevation_gain_m=payload.elevation_gain_m,
        elevation_loss_m=payload.elevation_loss_m,
    )
    try:
        ride_session = session_service.complete_session(
            session_id=session_id,
            user_id=current_user.id,
            completion=completion,
        )
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except ConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        ) from exc
    except ValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc

    return RideSessionPublic.model_validate(ride_session)


@router.get("/sessions/{session_id}", response_model=RideSessionPublic)
def get_session_detail(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    try:
        session = session_service.get_session(
            session_id=session_id,
            user_id=current_user.id,
        )
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc

    return RideSessionPublic.model_validate(session)


@router.get("/sessions/{session_id}/points", response_model=SessionPointsListResponse)
def list_session_points(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionPointsListResponse:
    try:
        points = session_service.list_session_points(
            session_id=session_id,
            user_id=current_user.id,
        )
    except NotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc

    return SessionPointsListResponse(
        session_id=session_id,
        items=[SessionPointPublic.model_validate(point) for point in points],
    )


@router.get("/users/me/sessions", response_model=SessionListResponse)
def list_user_sessions(
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionListResponse:
    sessions, total = session_service.list_user_sessions(
        user_id=current_user.id,
        page=page,
        page_size=page_size,
    )
    return SessionListResponse(
        items=[RideSessionPublic.model_validate(session) for session in sessions],
        page=page,
        page_size=page_size,
        total=total,
    )
