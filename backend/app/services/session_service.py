from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from datetime import timedelta
import logging
import uuid

from sqlalchemy.exc import IntegrityError

from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.ride_session_action import RideSessionAction
from app.models.ride_session_override import RideSessionOverride
from app.models.session_point import SessionPoint
from app.repositories.protocols import ResortRepositoryProtocol
from app.repositories.protocols import RideSessionRepositoryProtocol
from app.repositories.protocols import SessionOverrideRepositoryProtocol
from app.repositories.protocols import SessionPointRepositoryProtocol
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionPointInput
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError
from app.services.session_analyzer import ActionRecord
from app.services.session_analyzer import AnalyzerInput
from app.services.session_analyzer import OverrideRecord
from app.services.session_analyzer import OverrideSpan
from app.services.session_analyzer import RawPoint
from app.services.session_analyzer import SessionAnalyzer
from app.services.session_analyzer import SessionMetadataInput
from app.services.session_analyzer import SessionSummaryFields

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SessionOverrideSpec:
    started_at: datetime
    ended_at: datetime
    motion_state: str


class SessionService:
    def __init__(
        self,
        ride_session_repository: RideSessionRepositoryProtocol,
        resort_repository: ResortRepositoryProtocol,
        session_point_repository: SessionPointRepositoryProtocol,
        session_override_repository: SessionOverrideRepositoryProtocol,
        session_analyzer: SessionAnalyzer,
    ) -> None:
        self._ride_session_repository = ride_session_repository
        self._resort_repository = resort_repository
        self._session_point_repository = session_point_repository
        self._session_override_repository = session_override_repository
        self._session_analyzer = session_analyzer

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

        ride_session.ended_at = ended_at
        ride_session.status = RideSessionStatus.COMPLETED

        self._run_analysis(ride_session)

        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        return ride_session

    def reanalyze_session(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
    ) -> RideSession:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status == RideSessionStatus.DRAFT:
            raise ConflictError("Only completed sessions can be analyzed.")

        self._run_analysis(ride_session)

        self._ride_session_repository.commit()
        self._ride_session_repository.refresh(ride_session)
        return ride_session

    def apply_override(
        self,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        override_spec: SessionOverrideSpec,
    ) -> RideSession:
        ride_session = self._get_owned_session(session_id=session_id, user_id=user_id)
        if ride_session.status == RideSessionStatus.DRAFT:
            raise ConflictError("Only completed sessions can receive overrides.")
        if override_spec.ended_at < override_spec.started_at:
            raise ValidationError("Override ended_at must be >= started_at.")

        override = RideSessionOverride(
            session_id=ride_session.id,
            started_at=override_spec.started_at,
            ended_at=override_spec.ended_at,
            motion_state=override_spec.motion_state,
            created_by="user",
        )
        self._session_override_repository.add(override)
        self._session_override_repository.commit()

        return self.reanalyze_session(session_id=session_id, user_id=user_id)

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

    def _run_analysis(self, ride_session: RideSession) -> None:
        raw_points = self._session_point_repository.list_by_session(ride_session.id)
        existing_overrides = self._session_override_repository.list_by_session(ride_session.id)

        record_end = ride_session.ended_at or ride_session.started_at
        metadata = SessionMetadataInput(
            record_start=ride_session.started_at,
            record_end=record_end,
            resort_id=ride_session.resort_id,
            source=ride_session.source,
        )

        analyzer_input = AnalyzerInput(
            points=[_to_raw_point(p) for p in raw_points],
            metadata=metadata,
            preset_overrides=[_to_override_span(o) for o in existing_overrides],
        )
        result = self._session_analyzer.analyze(analyzer_input)

        self._ride_session_repository.update_analysis_result(
            session_id=ride_session.id,
            summary_fields=_summary_to_fields(result.summary),
            actions=[_to_action_model(a) for a in result.actions],
            overrides=[_to_override_model(o) for o in result.overrides],
            version=result.analyzer_version,
        )

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
        return [p for p in points if p.elapsed_offset_ms not in existing_elapsed_offsets_ms]

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

        latest_existing_elapsed_offsets_ms = (
            self._session_point_repository.existing_elapsed_offsets_ms(
                session_id=session_id,
                elapsed_offsets_ms=[point.elapsed_offset_ms for point in points],
            )
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
            raise ConflictError("Duplicate point offsets detected while uploading points.") from exc

    def _build_models(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        points: Sequence[SessionPointInput],
    ) -> list[SessionPoint]:
        return [self._build_point_with_analytics(ride_session, session_id, p) for p in points]

    def _build_point_with_analytics(
        self,
        ride_session: RideSession,
        session_id: uuid.UUID,
        point: SessionPointInput,
    ) -> SessionPoint:
        session_point = SessionPoint(
            session_id=session_id,
            t_offset_ms=point.elapsed_offset_ms,
            recorded_at=point.recorded_at
            or ride_session.started_at + timedelta(milliseconds=point.elapsed_offset_ms),
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
        )
        return session_point


def _to_raw_point(point: SessionPoint) -> RawPoint:
    return RawPoint(
        t_offset_ms=point.t_offset_ms,
        recorded_at=point.recorded_at,
        latitude=point.latitude,
        longitude=point.longitude,
        altitude_m=point.altitude_m,
        speed_mps=point.speed_mps,
        accuracy_m=point.accuracy_m,
        vertical_accuracy_m=point.vertical_accuracy_m,
    )


def _to_override_span(override: RideSessionOverride) -> OverrideSpan:
    return OverrideSpan(
        started_at=override.started_at,
        ended_at=override.ended_at,
        motion_state=override.motion_state,
        created_by=override.created_by,
    )


def _summary_to_fields(summary: SessionSummaryFields) -> dict[str, float | None]:
    return {
        "total_duration_s": summary.total_duration_s,
        "descent_duration_s": summary.descent_duration_s,
        "lift_duration_s": summary.lift_duration_s,
        "descent_distance_m": summary.descent_distance_m,
        "lift_distance_m": summary.lift_distance_m,
        "descent_vertical_m": summary.descent_vertical_m,
        "lift_vertical_m": summary.lift_vertical_m,
        "max_speed_mps": summary.max_speed_mps,
        "avg_descent_speed_mps": summary.avg_descent_speed_mps or 0.0,
        "peak_altitude_m": summary.peak_altitude_m,
        "center_lat": summary.center_lat,
        "center_long": summary.center_long,
        "altitude_offset_m": summary.altitude_offset_m,
    }


def _to_action_model(action: ActionRecord) -> RideSessionAction:
    return RideSessionAction(
        action_type=action.action_type,
        sequence_index=action.sequence_index,
        started_at=action.started_at,
        ended_at=action.ended_at,
        duration_s=action.duration_s,
        distance_m=action.distance_m,
        avg_speed_mps=action.avg_speed_mps,
        min_speed_mps=action.min_speed_mps,
        max_speed_mps=action.max_speed_mps,
        vertical_m=action.vertical_m,
        min_altitude_m=action.min_altitude_m,
        max_altitude_m=action.max_altitude_m,
        min_lat=action.min_lat,
        max_lat=action.max_lat,
        min_long=action.min_long,
        max_long=action.max_long,
        top_speed_lat=action.top_speed_lat,
        top_speed_long=action.top_speed_long,
        top_speed_alt_m=action.top_speed_alt_m,
        time_of_day=action.time_of_day,
        external_track_id=action.external_track_id,
        source=action.source,
    )


def _to_override_model(override: OverrideRecord) -> RideSessionOverride:
    return RideSessionOverride(
        started_at=override.started_at,
        ended_at=override.ended_at,
        motion_state=override.motion_state,
        created_by=override.created_by,
    )
