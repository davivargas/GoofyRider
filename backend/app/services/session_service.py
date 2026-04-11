import logging
import uuid
from collections.abc import Sequence
from datetime import UTC
from datetime import datetime
from datetime import timedelta

from sqlalchemy.exc import IntegrityError

from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.session_point import SessionPoint
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import RideSessionRepositoryProtocol
from app.repositories.protocols import SessionPointRepositoryProtocol
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionPointInput
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError


logger = logging.getLogger(__name__)


class SessionService:
    def __init__(
        self,
        ride_session_repository: RideSessionRepositoryProtocol,
        resort_repository: ResortRepositoryProtocol,
        session_point_repository: SessionPointRepositoryProtocol,
    ) -> None:
        self._ride_session_repository = ride_session_repository
        self._resort_repository = resort_repository
        self._session_point_repository = session_point_repository

    def create_session(
        self,
        *,
        user_id: uuid.UUID,
        request: SessionCreateRequest,
    ) -> RideSession:
        if request.resort_id is not None:
            resort = self._resort_repository.get_by_id(request.resort_id)
            if resort is None:
                raise NotFoundError("Resort not found.")

        ride_session = RideSession(
            user_id=user_id,
            resort_id=request.resort_id,
            started_at=request.started_at or datetime.now(UTC),
            status=RideSessionStatus.DRAFT,
        )
        self._ride_session_repository.add(ride_session)
        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        logger.info("Session created: %s for user: %s", ride_session.id, user_id)
        return ride_session

    def upload_points_batch(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        points: Sequence[SessionPointInput],
    ) -> int:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status != RideSessionStatus.DRAFT:
            raise ConflictError("Points can only be uploaded to draft sessions.")

        deduped_points = self._dedupe_points_by_elapsed_offset(points)
        requested_elapsed_offsets_ms = [point.elapsed_offset_ms for point in deduped_points]
        existing_elapsed_offsets_ms = self._session_point_repository.existing_elapsed_offsets_ms(
            session_id=ride_session.id,
            elapsed_offsets_ms=requested_elapsed_offsets_ms,
        )

        count = self._insert_new_points_with_idempotency(
            ride_session=ride_session,
            session_id=ride_session.id,
            points=deduped_points,
            existing_elapsed_offsets_ms=existing_elapsed_offsets_ms,
        )
        logger.info("Points uploaded: %d for session: %s", count, session_id)
        return count

    def complete_session(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        completion: SessionCompleteRequest,
    ) -> RideSession:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status != RideSessionStatus.DRAFT:
            raise ConflictError("Only draft sessions can be completed.")

        ended_at = completion.ended_at or datetime.now(UTC)
        if ended_at < ride_session.started_at:
            raise ValidationError("ended_at cannot be earlier than started_at.")

        duration_s = completion.duration_s
        if duration_s is None:
            duration_s = int((ended_at - ride_session.started_at).total_seconds())

        ride_session.ended_at = ended_at
        ride_session.duration_s = duration_s
        ride_session.distance_m = completion.distance_m
        ride_session.max_speed_mps = completion.max_speed_mps
        ride_session.avg_speed_mps = completion.avg_speed_mps
        ride_session.elevation_gain_m = completion.elevation_gain_m
        ride_session.elevation_loss_m = completion.elevation_loss_m
        ride_session.status = RideSessionStatus.COMPLETED

        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        return ride_session

    def get_session(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession:
        return self._get_owned_session(session_id=session_id, user_id=user_id)

    def list_session_points(self, session_id: uuid.UUID, user_id: uuid.UUID) -> list[SessionPoint]:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        return self._session_point_repository.list_by_session(ride_session.id)

    def list_user_sessions(
        self,
        user_id: uuid.UUID,
        page: int,
        page_size: int,
    ) -> tuple[list[RideSession], int]:
        return self._ride_session_repository.list_by_user_with_count(user_id, page, page_size)

    def delete_session(self, session_id: uuid.UUID, user_id: uuid.UUID) -> None:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        self._ride_session_repository.delete(ride_session)
        self._ride_session_repository.commit()

    def _get_owned_session(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession:
        ride_session = self._ride_session_repository.get_owned_by_user(session_id, user_id)
        if ride_session is None:
            raise NotFoundError("Session not found.")
        return ride_session

    def _dedupe_points_by_elapsed_offset(
        self,
        points: Sequence[SessionPointInput],
    ) -> list[SessionPointInput]:
        deduped: list[SessionPointInput] = []
        seen_elapsed_offsets_ms: set[int] = set()
        for point in points:
            if point.elapsed_offset_ms in seen_elapsed_offsets_ms:
                continue
            seen_elapsed_offsets_ms.add(point.elapsed_offset_ms)
            deduped.append(point)
        return deduped

    def _filter_new_points(
        self,
        points: Sequence[SessionPointInput],
        existing_elapsed_offsets_ms: set[int],
    ) -> list[SessionPointInput]:
        return [
            p for p in points
            if p.elapsed_offset_ms not in existing_elapsed_offsets_ms
        ]

    def _insert_new_points_with_idempotency(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        points: Sequence[SessionPointInput],
        existing_elapsed_offsets_ms: set[int],
    ) -> int:
        new_points = self._filter_new_points(points, existing_elapsed_offsets_ms)
        if not new_points:
            return 0

        models = self._build_models(
            ride_session=ride_session,
            session_id=session_id,
            points=new_points,
        )

        try:
            self._session_point_repository.add_batch(models)
            self._session_point_repository.commit()
            return len(models)
        except IntegrityError:
            self._session_point_repository.rollback()

        latest_existing_elapsed_offsets_ms = self._session_point_repository.existing_elapsed_offsets_ms(
            session_id=session_id,
            elapsed_offsets_ms=[point.elapsed_offset_ms for point in points],
        )
        retry_new_points = self._filter_new_points(points, latest_existing_elapsed_offsets_ms)
        if not retry_new_points:
            return 0

        retry_models = self._build_models(
            ride_session=ride_session,
            session_id=session_id,
            points=retry_new_points,
        )

        try:
            self._session_point_repository.add_batch(retry_models)
            self._session_point_repository.commit()
            return len(retry_models)
        except IntegrityError as exc:
            self._session_point_repository.rollback()
            logger.warning("Duplicate points detected for session: %s", session_id)
            raise ConflictError(
                "Duplicate point offsets detected while uploading points."
            ) from exc

    def _build_models(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        points: Sequence[SessionPointInput],
    ) -> list[SessionPoint]:
        return [
            SessionPoint(
                session_id=session_id,
                t_offset_ms=point.elapsed_offset_ms,
                recorded_at=point.recorded_at
                or ride_session.started_at
                + timedelta(milliseconds=point.elapsed_offset_ms),
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
                accepted_for_analytics=point.accepted_for_analytics,
            )
            for point in points
        ]
