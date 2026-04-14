import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Request
from fastapi import status
from pydantic import ValidationError as PydanticValidationError

from app.core.dependencies import get_current_user
from app.core.dependencies import get_session_service
from app.models.user import User
from app.schemas.session import RideSessionPublic
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionPointPublic
from app.schemas.session import SessionPointsBatchRequest
from app.schemas.session import SessionPointsBatchResponse
from app.schemas.session import SessionPointsListResponse
from app.services.session_service import SessionService

router = APIRouter(tags=["sessions"])


async def _parse_session_completion_payload(request: Request) -> SessionCompleteRequest:
    try:
        body = await request.json()
    except ValueError:
        body = {}
    try:
        return SessionCompleteRequest.model_validate(body)
    except PydanticValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "message": "Invalid session completion payload.",
                "errors": [
                    {"field": str(error["loc"][-1]), "message": error["msg"]}
                    for error in exc.errors()
                ],
            },
        ) from exc


@router.post("/sessions", response_model=RideSessionPublic, status_code=status.HTTP_201_CREATED)
def create_session(
    payload: SessionCreateRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    ride_session = session_service.create_session(
        user_id=current_user.id,
        request=payload,
    )
    return RideSessionPublic.model_validate(ride_session)


@router.post("/sessions/{session_id}/points:batch", response_model=SessionPointsBatchResponse)
def upload_session_points_batch(
    session_id: uuid.UUID,
    payload: SessionPointsBatchRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionPointsBatchResponse:
    inserted_count = session_service.upload_points_batch(
        session_id=session_id,
        user_id=current_user.id,
        points=payload.points,
    )
    return SessionPointsBatchResponse(session_id=session_id, inserted_count=inserted_count)


@router.post("/sessions/{session_id}/complete", response_model=RideSessionPublic)
def complete_session(
    session_id: uuid.UUID,
    payload: SessionCompleteRequest = Depends(_parse_session_completion_payload),
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    ride_session = session_service.complete_session(
        session_id=session_id,
        user_id=current_user.id,
        completion=payload,
    )
    return RideSessionPublic.model_validate(ride_session)


@router.get("/sessions/{session_id}", response_model=RideSessionPublic)
def get_session_detail(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    session = session_service.get_session(
        session_id=session_id,
        user_id=current_user.id,
    )
    return RideSessionPublic.model_validate(session)


@router.get("/sessions/{session_id}/points", response_model=SessionPointsListResponse)
def list_session_points(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionPointsListResponse:
    points = session_service.list_session_points(
        session_id=session_id,
        user_id=current_user.id,
    )
    return SessionPointsListResponse(
        session_id=session_id,
        items=[SessionPointPublic.from_session_point(point) for point in points],
    )


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_session(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> None:
    session_service.delete_session(
        session_id=session_id,
        user_id=current_user.id,
    )
