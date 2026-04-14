from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import pytest

from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionPointInput
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ValidationError
from app.services.session_service import SessionService


class FakeResortRepository:
    def __init__(self) -> None:
        self.resort_ids: set[object] = set()

    def get_by_id(self, resort_id):
        if resort_id in self.resort_ids:
            return object()
        return None


class FakeRideSessionRepository:
    def __init__(self) -> None:
        self.sessions: dict[object, RideSession] = {}
        self.did_commit = False
        self.deleted_session_ids: list[object] = []

    def add(self, ride_session: RideSession) -> None:
        if ride_session.id is None:
            ride_session.id = uuid4()
        self.sessions[ride_session.id] = ride_session

    def get_owned_by_user(self, session_id, user_id):
        session = self.sessions.get(session_id)
        if session is None or session.user_id != user_id:
            return None
        return session

    def delete(self, ride_session: RideSession) -> None:
        self.deleted_session_ids.append(ride_session.id)
        self.sessions.pop(ride_session.id, None)

    def count_by_user(self, user_id):
        return sum(1 for session in self.sessions.values() if session.user_id == user_id)

    def list_by_user(self, user_id, page, page_size):
        owned = [session for session in self.sessions.values() if session.user_id == user_id]
        start = (page - 1) * page_size
        end = start + page_size
        return owned[start:end]

    def commit(self):
        self.did_commit = True

    def refresh(self, _instance: object):
        return None


class FakeSessionPointRepository:
    def __init__(self) -> None:
        self.batches: list[list[object]] = []
        self.did_commit = False
        self.did_rollback = False
        self.offsets_by_session: dict[object, set[int]] = {}

    def add_batch(self, points):
        self.batches.append(list(points))
        for point in points:
            existing = self.offsets_by_session.setdefault(point.session_id, set())
            existing.add(point.t_offset_ms)

    def existing_elapsed_offsets_ms(self, session_id, elapsed_offsets_ms):
        return set(self.offsets_by_session.get(session_id, set())).intersection(
            set(elapsed_offsets_ms)
        )

    def list_by_session(self, _session_id):
        return []

    def commit(self):
        self.did_commit = True

    def rollback(self):
        self.did_rollback = True


def _build_service(
    ride_session_repository: FakeRideSessionRepository | None = None,
    resort_repository: FakeResortRepository | None = None,
    session_point_repository: FakeSessionPointRepository | None = None,
) -> SessionService:
    return SessionService(
        ride_session_repository=ride_session_repository or FakeRideSessionRepository(),
        resort_repository=resort_repository or FakeResortRepository(),
        session_point_repository=session_point_repository or FakeSessionPointRepository(),
    )


def _build_session(user_id, status: RideSessionStatus = RideSessionStatus.DRAFT) -> RideSession:
    session = RideSession(
        user_id=user_id,
        resort_id=None,
        started_at=datetime.now(UTC) - timedelta(minutes=10),
        status=status,
    )
    session.id = uuid4()
    return session


def test_create_session_rejects_unknown_resort() -> None:
    service = _build_service()

    with pytest.raises(NotFoundError, match=r"Resort not found."):
        service.create_session(
            user_id=uuid4(),
            request=SessionCreateRequest(
                resort_id=uuid4(),
            ),
        )


def test_upload_points_batch_rejects_non_draft_session() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session
    service = _build_service(ride_session_repository=ride_sessions)

    with pytest.raises(ConflictError, match=r"Points can only be uploaded to draft sessions."):
        service.upload_points_batch(
            session_id=completed_session.id,
            user_id=user_id,
            points=[
                SessionPointInput(t_offset_ms=0, latitude=50.0, longitude=-122.0),
            ],
        )


def test_complete_session_rejects_end_before_start() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)
    ended_at = draft_session.started_at - timedelta(seconds=1)

    with pytest.raises(ValidationError, match=r"ended_at cannot be earlier than started_at."):
        service.complete_session(
            session_id=draft_session.id,
            user_id=user_id,
            completion=SessionCompleteRequest(ended_at=ended_at),
        )


def test_complete_session_sets_computed_duration_when_missing() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)
    ended_at = draft_session.started_at + timedelta(seconds=30)

    completed = service.complete_session(
        session_id=draft_session.id,
        user_id=user_id,
        completion=SessionCompleteRequest(ended_at=ended_at),
    )

    assert completed.status == RideSessionStatus.COMPLETED
    assert completed.duration_s == 30


def test_complete_session_allows_omitted_optional_metrics() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)
    ended_at = draft_session.started_at + timedelta(seconds=45)

    completed = service.complete_session(
        session_id=draft_session.id,
        user_id=user_id,
        completion=SessionCompleteRequest(
            ended_at=ended_at,
            distance_m=None,
            max_speed_mps=None,
            avg_speed_mps=None,
            elevation_gain_m=None,
            elevation_loss_m=None,
        ),
    )

    assert completed.status == RideSessionStatus.COMPLETED
    assert completed.duration_s == 45
    assert completed.distance_m is None
    assert completed.max_speed_mps is None
    assert completed.avg_speed_mps is None
    assert completed.elevation_gain_m is None
    assert completed.elevation_loss_m is None


def test_complete_session_persists_valid_metrics() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)
    ended_at = draft_session.started_at + timedelta(seconds=60)

    completed = service.complete_session(
        session_id=draft_session.id,
        user_id=user_id,
        completion=SessionCompleteRequest(
            ended_at=ended_at,
            max_speed_mps=10.0,
            avg_speed_mps=8.0,
            distance_m=420.5,
            elevation_gain_m=22,
            elevation_loss_m=180,
        ),
    )

    assert completed.max_speed_mps == 10.0
    assert completed.avg_speed_mps == 8.0
    assert completed.distance_m == 420.5
    assert completed.elevation_gain_m == 22
    assert completed.elevation_loss_m == 180


def test_upload_points_batch_skips_existing_offsets() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    point_repo.offsets_by_session[draft_session.id] = {0}

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    inserted = service.upload_points_batch(
        session_id=draft_session.id,
        user_id=user_id,
        points=[
            SessionPointInput(t_offset_ms=0, latitude=50.0, longitude=-122.0),
            SessionPointInput(t_offset_ms=1000, latitude=50.001, longitude=-122.001),
        ],
    )

    assert inserted == 1


def test_upload_points_batch_dedupes_duplicate_offsets_in_single_request() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    inserted = service.upload_points_batch(
        session_id=draft_session.id,
        user_id=user_id,
        points=[
            SessionPointInput(t_offset_ms=0, latitude=50.0, longitude=-122.0),
            SessionPointInput(t_offset_ms=0, latitude=50.1, longitude=-122.1),
            SessionPointInput(t_offset_ms=1000, latitude=50.001, longitude=-122.001),
        ],
    )

    assert inserted == 2
    assert len(point_repo.batches) == 1
    inserted_offsets = {point.t_offset_ms for point in point_repo.batches[0]}
    assert inserted_offsets == {0, 1000}


def test_upload_points_batch_populates_legacy_defaults_when_fields_omitted() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    draft_session.started_at = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)
    ride_sessions.sessions[draft_session.id] = draft_session

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    inserted = service.upload_points_batch(
        session_id=draft_session.id,
        user_id=user_id,
        points=[
            SessionPointInput(
                t_offset_ms=1500,
                latitude=50.95,
                longitude=-118.16,
            )
        ],
    )

    assert inserted == 1
    stored_point = point_repo.batches[0][0]
    assert stored_point.recorded_at == datetime(2026, 1, 1, 0, 0, 1, 500000, tzinfo=UTC)
    assert stored_point.accepted_for_analytics is True
    assert stored_point.analytics is not None
    assert stored_point.analytics.accepted_for_analytics is True
    assert stored_point.analytics.quality_class is None
    assert stored_point.analytics.motion_state is None


def test_upload_points_batch_preserves_enriched_point_fields() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    inserted = service.upload_points_batch(
        session_id=draft_session.id,
        user_id=user_id,
        points=[
            SessionPointInput(
                t_offset_ms=0,
                latitude=50.95,
                longitude=-118.16,
                accuracy_m=3.2,
                elapsed_realtime_ns=123456789,
                recorded_at=datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC),
                altitude_m=1450.5,
                vertical_accuracy_m=4.1,
                speed_mps=6.4,
                speed_accuracy_mps=0.4,
                heading_deg=182.0,
                bearing_accuracy_deg=7.5,
                provider=" GPS ",
                is_mocked=False,
                quality_class="ACCEPT",
                quality_score=0.91,
                quality_reason="stable_fix",
                filtered_latitude=50.9501,
                filtered_longitude=-118.1601,
                filtered_altitude_m=1449.8,
                fused_speed_mps=6.1,
                derived_speed_mps=6.2,
                distance_delta_m=4.7,
                motion_state="ACTIVE DESCENT",
                accepted_for_analytics=True,
            )
        ],
    )

    assert inserted == 1
    stored_point = point_repo.batches[0][0]
    assert stored_point.elapsed_realtime_ns == 123456789
    assert stored_point.recorded_at == datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)
    assert stored_point.vertical_accuracy_m == 4.1
    assert stored_point.speed_accuracy_mps == 0.4
    assert stored_point.bearing_accuracy_deg == 7.5
    assert stored_point.provider == "gps"
    assert stored_point.is_mocked is False
    assert stored_point.quality_class == "accept"
    assert stored_point.quality_score == 0.91
    assert stored_point.quality_reason == "stable_fix"
    assert stored_point.filtered_latitude == 50.9501
    assert stored_point.filtered_longitude == -118.1601
    assert stored_point.filtered_altitude_m == 1449.8
    assert stored_point.fused_speed_mps == 6.1
    assert stored_point.derived_speed_mps == 6.2
    assert stored_point.distance_delta_m == 4.7
    assert stored_point.motion_state == "active_descent"
    assert stored_point.accepted_for_analytics is True

    analytics = stored_point.analytics
    assert analytics is not None
    assert analytics.quality_class == "accept"
    assert analytics.quality_score == 0.91
    assert analytics.quality_reason == "stable_fix"
    assert analytics.filtered_latitude == 50.9501
    assert analytics.filtered_longitude == -118.1601
    assert analytics.filtered_altitude_m == 1449.8
    assert analytics.fused_speed_mps == 6.1
    assert analytics.derived_speed_mps == 6.2
    assert analytics.distance_delta_m == 4.7
    assert analytics.motion_state == "active_descent"
    assert analytics.accepted_for_analytics is True


def test_upload_points_batch_preserves_richer_point_fields() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    inserted = service.upload_points_batch(
        session_id=draft_session.id,
        user_id=user_id,
        points=[
            SessionPointInput(
                t_offset_ms=0,
                latitude=50.0,
                longitude=-122.0,
                accuracy_m=3.2,
                elapsed_realtime_ns=123456789,
                recorded_at=datetime(2026, 1, 1, 0, 0, 5, tzinfo=UTC),
                altitude_m=1500.0,
                vertical_accuracy_m=4.4,
                speed_mps=7.5,
                speed_accuracy_mps=0.8,
                heading_deg=42.0,
                bearing_accuracy_deg=6.0,
                provider="FusedLocationProvider",
                is_mocked=False,
                quality_class="accept_low_confidence",
                quality_score=0.9,
                quality_reason="strong_fix",
                filtered_latitude=50.0001,
                filtered_longitude=-122.0001,
                filtered_altitude_m=1499.5,
                fused_speed_mps=7.4,
                derived_speed_mps=7.3,
                distance_delta_m=1.2,
                motion_state="Lift Uphill",
                accepted_for_analytics=False,
            )
        ],
    )

    assert inserted == 1
    saved_point = point_repo.batches[0][0]
    assert saved_point.elapsed_realtime_ns == 123456789
    assert saved_point.recorded_at == datetime(2026, 1, 1, 0, 0, 5, tzinfo=UTC)
    assert saved_point.vertical_accuracy_m == 4.4
    assert saved_point.speed_accuracy_mps == 0.8
    assert saved_point.bearing_accuracy_deg == 6.0
    assert saved_point.provider == "fused"
    assert saved_point.is_mocked is False
    assert saved_point.quality_class == "accept_low_confidence"
    assert saved_point.quality_score == 0.9
    assert saved_point.quality_reason == "strong_fix"
    assert saved_point.filtered_latitude == 50.0001
    assert saved_point.filtered_longitude == -122.0001
    assert saved_point.filtered_altitude_m == 1499.5
    assert saved_point.fused_speed_mps == 7.4
    assert saved_point.derived_speed_mps == 7.3
    assert saved_point.distance_delta_m == 1.2
    assert saved_point.motion_state == "lift_uphill"
    assert saved_point.accepted_for_analytics is False


def test_delete_session_removes_owned_session() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[session.id] = session
    service = _build_service(ride_session_repository=ride_sessions)

    service.delete_session(session_id=session.id, user_id=user_id)

    assert ride_sessions.did_commit is True
    assert ride_sessions.deleted_session_ids == [session.id]
    assert session.id not in ride_sessions.sessions


def test_delete_session_rejects_unknown_or_unowned_session() -> None:
    owner_id = uuid4()
    attacker_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    session = _build_session(user_id=owner_id, status=RideSessionStatus.DRAFT)
    ride_sessions.sessions[session.id] = session
    service = _build_service(ride_session_repository=ride_sessions)

    with pytest.raises(NotFoundError, match=r"Session not found."):
        service.delete_session(session_id=session.id, user_id=attacker_id)

    with pytest.raises(NotFoundError, match=r"Session not found."):
        service.delete_session(session_id=uuid4(), user_id=owner_id)
