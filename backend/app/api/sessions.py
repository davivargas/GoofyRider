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
from app.schemas.session import SessionActionRead
from app.schemas.session import SessionActionsListResponse
from app.schemas.session import SessionAnalyzeRequest
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionDetailResponse
from app.schemas.session import SessionOverrideCreateRequest
from app.schemas.session import SessionOverrideRead
from app.schemas.session import SessionPointPublic
from app.schemas.session import SessionPointsBatchRequest
from app.schemas.session import SessionPointsBatchResponse
from app.schemas.session import SessionPointsListResponse
from app.schemas.session import SessionSummary
from app.schemas.session import SessionUpdateRequest
from app.services.session_service import SessionDetail
from app.services.session_service import SessionOverrideSpec
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


async def _parse_session_analyze_payload(request: Request) -> SessionAnalyzeRequest:
    try:
        body = await request.json()
    except ValueError:
        body = {}
    try:
        return SessionAnalyzeRequest.model_validate(body)
    except PydanticValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "message": "Invalid session analyze payload.",
                "errors": [
                    {"field": str(error["loc"][-1]), "message": error["msg"]}
                    for error in exc.errors()
                ],
            },
        ) from exc


def _detail_response(detail: SessionDetail) -> SessionDetailResponse:
    return SessionDetailResponse(
        session=SessionSummary.model_validate(detail.session),
        actions=[SessionActionRead.model_validate(a) for a in detail.actions],
        overrides=[SessionOverrideRead.model_validate(o) for o in detail.overrides],
    )


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


@router.post("/sessions/{session_id}/complete", response_model=SessionDetailResponse)
def complete_session(
    session_id: uuid.UUID,
    payload: SessionCompleteRequest = Depends(_parse_session_completion_payload),
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionDetailResponse:
    detail = session_service.complete_session(
        session_id=session_id,
        user_id=current_user.id,
        completion=payload,
    )
    return _detail_response(detail)


@router.post("/sessions/{session_id}/analyze", response_model=SessionDetailResponse)
def analyze_session(
    session_id: uuid.UUID,
    payload: SessionAnalyzeRequest = Depends(_parse_session_analyze_payload),
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionDetailResponse:
    detail = session_service.reanalyze_session(
        session_id=session_id,
        user_id=current_user.id,
        include_overrides=payload.include_overrides,
    )
    return _detail_response(detail)


@router.patch("/sessions/{session_id}", response_model=RideSessionPublic)
def update_session(
    session_id: uuid.UUID,
    payload: SessionUpdateRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> RideSessionPublic:
    ride_session = session_service.update_session_metadata(
        session_id=session_id,
        user_id=current_user.id,
        update=payload,
    )
    return RideSessionPublic.model_validate(ride_session)


@router.post("/sessions/{session_id}/overrides", response_model=SessionDetailResponse)
def create_session_override(
    session_id: uuid.UUID,
    payload: SessionOverrideCreateRequest,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionDetailResponse:
    detail = session_service.apply_override(
        session_id=session_id,
        user_id=current_user.id,
        override_spec=SessionOverrideSpec(
            started_at=payload.started_at,
            ended_at=payload.ended_at,
            motion_state=payload.motion_state,
        ),
    )
    return _detail_response(detail)


@router.delete(
    "/sessions/{session_id}/overrides/{override_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def delete_session_override(
    session_id: uuid.UUID,
    override_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> None:
    session_service.remove_override(
        session_id=session_id,
        user_id=current_user.id,
        override_id=override_id,
    )


@router.get("/sessions/{session_id}", response_model=SessionDetailResponse)
def get_session_detail(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionDetailResponse:
    detail = session_service.get_session_detail(
        session_id=session_id,
        user_id=current_user.id,
    )
    return _detail_response(detail)


@router.get("/sessions/{session_id}/actions", response_model=SessionActionsListResponse)
def list_session_actions(
    session_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    session_service: SessionService = Depends(get_session_service),
) -> SessionActionsListResponse:
    actions = session_service.list_session_actions(
        session_id=session_id,
        user_id=current_user.id,
    )
    return SessionActionsListResponse(
        session_id=session_id,
        items=[SessionActionRead.model_validate(a) for a in actions],
    )


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
