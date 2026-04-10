import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from math import isfinite
from typing import Protocol

from sqlalchemy.exc import IntegrityError

from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.session_point import SessionPoint
from app.schemas.session_vocabulary import normalize_motion_state
from app.schemas.session_vocabulary import normalize_provider
from app.schemas.session_vocabulary import normalize_quality_class
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError


@dataclass(frozen=True)
class SessionCreateInput:
    user_id: uuid.UUID
    resort_id: uuid.UUID | None = None
    started_at: datetime | None = None


@dataclass(frozen=True)
class SessionPointInputData:
    t_offset_ms: int
    latitude: float
    longitude: float
    accuracy_m: float | None = None
    elapsed_realtime_ns: int | None = None
    recorded_at: datetime | None = None
    altitude_m: float | None = None
    vertical_accuracy_m: float | None = None
    speed_mps: float | None = None
    speed_accuracy_mps: float | None = None
    heading_deg: float | None = None
    bearing_accuracy_deg: float | None = None
    provider: str | None = None
    is_mocked: bool | None = None
    quality_class: str | None = None
    quality_score: float | None = None
    quality_reason: str | None = None
    filtered_latitude: float | None = None
    filtered_longitude: float | None = None
    filtered_altitude_m: float | None = None
    fused_speed_mps: float | None = None
    derived_speed_mps: float | None = None
    distance_delta_m: float | None = None
    motion_state: str | None = None
    accepted_for_analytics: bool = True


@dataclass(frozen=True)
class SessionCompletionInput:
    ended_at: datetime | None = None
    duration_s: int | None = None
    distance_m: float | None = None
    max_speed_mps: float | None = None
    avg_speed_mps: float | None = None
    elevation_gain_m: int | None = None
    elevation_loss_m: int | None = None


class ResortRepositoryProtocol(Protocol):
    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        ...


class RideSessionRepositoryProtocol(Protocol):
    def add(self, ride_session: RideSession) -> None:
        ...

    def delete(self, ride_session: RideSession) -> None:
        ...

    def get_owned_by_user(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession | None:
        ...

    def count_by_user(self, user_id: uuid.UUID) -> int:
        ...

    def list_by_user(self, user_id: uuid.UUID, page: int, page_size: int) -> list[RideSession]:
        ...

    def commit(self) -> None:
        ...

    def refresh(self, instance: object) -> None:
        ...


class SessionPointRepositoryProtocol(Protocol):
    def add_batch(self, points: Sequence[SessionPoint]) -> None:
        ...

    def existing_offsets(self, session_id: uuid.UUID, offsets: Sequence[int]) -> set[int]:
        ...

    def list_by_session(self, session_id: uuid.UUID) -> list[SessionPoint]:
        ...

    def commit(self) -> None:
        ...

    def rollback(self) -> None:
        ...


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

    def create_session(self, request: SessionCreateInput) -> RideSession:
        if request.resort_id is not None:
            resort = self._resort_repository.get_by_id(request.resort_id)
            if resort is None:
                raise NotFoundError("Resort not found.")

        ride_session = RideSession(
            user_id=request.user_id,
            resort_id=request.resort_id,
            started_at=request.started_at or datetime.now(UTC),
            status=RideSessionStatus.DRAFT,
        )
        self._ride_session_repository.add(ride_session)
        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        return ride_session

    def upload_points_batch(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        points: Sequence[SessionPointInputData],
    ) -> int:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status != RideSessionStatus.DRAFT:
            raise ConflictError("Points can only be uploaded to draft sessions.")

        deduped_points = self._dedupe_points_by_offset(points)
        requested_offsets = [point.t_offset_ms for point in deduped_points]
        existing_offsets = self._session_point_repository.existing_offsets(
            session_id=ride_session.id,
            offsets=requested_offsets,
        )

        return self._insert_new_points_with_idempotency(
            ride_session=ride_session,
            session_id=ride_session.id,
            points=deduped_points,
            existing_offsets=existing_offsets,
        )

    def complete_session(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        completion: SessionCompletionInput,
    ) -> RideSession:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status != RideSessionStatus.DRAFT:
            raise ConflictError("Only draft sessions can be completed.")

        ended_at = completion.ended_at or datetime.now(UTC)
        if ended_at < ride_session.started_at:
            raise ValidationError("ended_at cannot be earlier than started_at.")

        sanitized_completion = self._sanitize_completion_metrics(completion)

        duration_s = sanitized_completion.duration_s
        if duration_s is None:
            duration_s = int((ended_at - ride_session.started_at).total_seconds())
        if duration_s < 0:
            raise ValidationError("duration_s must be non-negative.")

        ride_session.ended_at = ended_at
        ride_session.duration_s = duration_s
        ride_session.distance_m = sanitized_completion.distance_m
        ride_session.max_speed_mps = sanitized_completion.max_speed_mps
        ride_session.avg_speed_mps = sanitized_completion.avg_speed_mps
        ride_session.elevation_gain_m = sanitized_completion.elevation_gain_m
        ride_session.elevation_loss_m = sanitized_completion.elevation_loss_m
        ride_session.status = RideSessionStatus.COMPLETED

        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        return ride_session

    def _sanitize_completion_metrics(
        self,
        completion: SessionCompletionInput,
    ) -> SessionCompletionInput:
        distance_m = self._sanitize_optional_non_negative_float(completion.distance_m)
        max_speed_mps = self._sanitize_optional_non_negative_float(completion.max_speed_mps)
        avg_speed_mps = self._sanitize_optional_non_negative_float(completion.avg_speed_mps)
        elevation_gain_m = self._sanitize_optional_non_negative_int(completion.elevation_gain_m)
        elevation_loss_m = self._sanitize_optional_non_negative_int(completion.elevation_loss_m)

        if (
            avg_speed_mps is not None
            and max_speed_mps is not None
            and avg_speed_mps > max_speed_mps
        ):
            raise ValidationError("avg_speed_mps must be less than or equal to max_speed_mps.")

        return SessionCompletionInput(
            ended_at=completion.ended_at,
            duration_s=completion.duration_s,
            distance_m=distance_m,
            max_speed_mps=max_speed_mps,
            avg_speed_mps=avg_speed_mps,
            elevation_gain_m=elevation_gain_m,
            elevation_loss_m=elevation_loss_m,
        )

    def _sanitize_optional_non_negative_float(self, value: float | None) -> float | None:
        if value is None:
            return None
        if value < 0 or not isfinite(value):
            return None
        return value

    def _sanitize_optional_non_negative_int(self, value: int | None) -> int | None:
        if value is None:
            return None
        if value < 0:
            return None
        return value

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
        total = self._ride_session_repository.count_by_user(user_id)
        sessions = self._ride_session_repository.list_by_user(user_id, page, page_size)
        return sessions, total

    def delete_session(self, session_id: uuid.UUID, user_id: uuid.UUID) -> None:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        self._ride_session_repository.delete(ride_session)
        self._ride_session_repository.commit()

    def _get_owned_session(self, session_id: uuid.UUID, user_id: uuid.UUID) -> RideSession:
        ride_session = self._ride_session_repository.get_owned_by_user(session_id, user_id)
        if ride_session is None:
            raise NotFoundError("Session not found.")
        return ride_session

    def _dedupe_points_by_offset(
        self,
        points: Sequence[SessionPointInputData],
    ) -> list[SessionPointInputData]:
        deduped: list[SessionPointInputData] = []
        seen_offsets: set[int] = set()
        for point in points:
            if point.t_offset_ms in seen_offsets:
                continue
            seen_offsets.add(point.t_offset_ms)
            deduped.append(point)
        return deduped

    def _insert_new_points_with_idempotency(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        points: Sequence[SessionPointInputData],
        existing_offsets: set[int],
    ) -> int:
        models = self._build_models(
            ride_session=ride_session,
            session_id=session_id,
            points=points,
            existing_offsets=existing_offsets,
        )
        if not models:
            return 0

        try:
            self._session_point_repository.add_batch(models)
            self._session_point_repository.commit()
            return len(models)
        except IntegrityError:
            self._session_point_repository.rollback()

        latest_existing_offsets = self._session_point_repository.existing_offsets(
            session_id=session_id,
            offsets=[point.t_offset_ms for point in points],
        )
        retry_models = self._build_models(
            ride_session=ride_session,
            session_id=session_id,
            points=points,
            existing_offsets=latest_existing_offsets,
        )
        if not retry_models:
            return 0

        try:
            self._session_point_repository.add_batch(retry_models)
            self._session_point_repository.commit()
            return len(retry_models)
        except IntegrityError as exc:
            self._session_point_repository.rollback()
            raise ConflictError(
                "Duplicate point offsets detected while uploading points."
            ) from exc

    def _build_models(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        points: Sequence[SessionPointInputData],
        existing_offsets: set[int],
    ) -> list[SessionPoint]:
        return [
            SessionPoint(
                session_id=session_id,
                t_offset_ms=point.t_offset_ms,
                recorded_at=point.recorded_at
                or ride_session.started_at + timedelta(milliseconds=point.t_offset_ms),
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
                provider=normalize_provider(point.provider),
                is_mocked=point.is_mocked,
                quality_class=normalize_quality_class(point.quality_class),
                quality_score=point.quality_score,
                quality_reason=point.quality_reason,
                filtered_latitude=point.filtered_latitude,
                filtered_longitude=point.filtered_longitude,
                filtered_altitude_m=point.filtered_altitude_m,
                fused_speed_mps=point.fused_speed_mps,
                derived_speed_mps=point.derived_speed_mps,
                distance_delta_m=point.distance_delta_m,
                motion_state=normalize_motion_state(point.motion_state),
                accepted_for_analytics=point.accepted_for_analytics,
            )
            for point in points
            if point.t_offset_ms not in existing_offsets
        ]
