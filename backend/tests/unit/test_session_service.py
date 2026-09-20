from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

import pytest

from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.ride_session_override import RideSessionOverride
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionCreateRequest
from app.schemas.session import SessionPointInput
from app.schemas.session import SessionUpdateRequest
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import SessionNotYetCompletedError
from app.services.exceptions import ValidationError
from app.services.session_analyzer import AnalysisResult
from app.services.session_analyzer import AnalyzerInput
from app.services.session_analyzer import SessionAnalyzer
from app.services.session_analyzer import SessionSummaryFields
from app.services.session_service import SessionDetail
from app.services.session_service import SessionOverrideSpec
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
        self.analysis_updates: list[dict[str, object]] = []

    def add(self, ride_session: RideSession) -> None:
        if ride_session.id is None:
            ride_session.id = uuid4()
        self.sessions[ride_session.id] = ride_session

    def get_owned_by_user(self, session_id, user_id):
        session = self.sessions.get(session_id)
        if session is None or session.user_id != user_id:
            return None
        return session

    def get_detail_with_actions(self, session_id):
        session = self.sessions.get(session_id)
        if session is None:
            return None
        if not hasattr(session, "actions") or session.actions is None:
            session.actions = []
        if not hasattr(session, "overrides") or session.overrides is None:
            session.overrides = []
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

    def update_analysis_result(
        self,
        session_id,
        *,
        summary_fields,
        actions,
        overrides,
        version,
    ):
        self.analysis_updates.append(
            {
                "session_id": session_id,
                "summary_fields": dict(summary_fields),
                "actions": list(actions),
                "overrides": list(overrides),
                "version": version,
            }
        )
        session = self.sessions.get(session_id)
        if session is None:
            return
        for field, value in summary_fields.items():
            setattr(session, field, value)
        session.processed_by_version = version
        session.actions = list(actions)
        session.overrides = list(overrides)


class FakeSessionOverrideRepository:
    def __init__(self) -> None:
        self.overrides_by_session: dict[object, list[RideSessionOverride]] = {}
        self.deleted_overrides: list[RideSessionOverride] = []

    def list_by_session(self, session_id):
        return list(self.overrides_by_session.get(session_id, []))

    def get_by_id(self, override_id):
        for overrides in self.overrides_by_session.values():
            for override in overrides:
                if override.id == override_id:
                    return override
        return None

    def delete(self, override):
        self.deleted_overrides.append(override)
        siblings = self.overrides_by_session.get(override.session_id, [])
        self.overrides_by_session[override.session_id] = [o for o in siblings if o is not override]

    def add(self, override):
        if getattr(override, "id", None) is None:
            override.id = uuid4()
        self.overrides_by_session.setdefault(override.session_id, []).append(override)

    def commit(self):
        return None


class _EmptyAnalysisAnalyzer:
    """Analyzer stub that records inputs and returns an empty AnalysisResult."""

    def __init__(self) -> None:
        self.calls: list[AnalyzerInput] = []

    def analyze(self, analyzer_input: AnalyzerInput) -> AnalysisResult:
        self.calls.append(analyzer_input)
        summary = SessionSummaryFields(
            total_duration_s=0.0,
            descent_duration_s=0.0,
            lift_duration_s=0.0,
            descent_distance_m=0.0,
            lift_distance_m=0.0,
            descent_vertical_m=0.0,
            lift_vertical_m=0.0,
            max_speed_mps=None,
            avg_descent_speed_mps=None,
            peak_altitude_m=None,
            center_lat=None,
            center_long=None,
            altitude_offset_m=0.0,
        )
        return AnalysisResult(
            summary=summary,
            actions=[],
            overrides=[],
            analyzer_version="analyzer@test",
        )


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

    def count_by_session(self, session_id):
        return len(self.offsets_by_session.get(session_id, set()))

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
    session_override_repository: FakeSessionOverrideRepository | None = None,
    session_analyzer: object | None = None,
) -> SessionService:
    return SessionService(
        ride_session_repository=ride_session_repository or FakeRideSessionRepository(),
        resort_repository=resort_repository or FakeResortRepository(),
        session_point_repository=session_point_repository or FakeSessionPointRepository(),
        session_override_repository=session_override_repository or FakeSessionOverrideRepository(),
        session_analyzer=session_analyzer or SessionAnalyzer(analyzer_version="analyzer@test"),
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


def test_upload_points_batch_populates_restore_contract_defaults_when_fields_omitted() -> None:
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


def test_upload_points_batch_preserves_raw_point_fields() -> None:
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


# --------------------------------------------------------------------------
# Step 6 — complete_session: no client-computed fields reach the service.
# --------------------------------------------------------------------------


def test_complete_session_does_not_read_client_computed_fields() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    analyzer = _EmptyAnalysisAnalyzer()

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_analyzer=analyzer,
    )

    # Extra keys that resemble the deleted client-computed fields are silently
    # stripped by the schema; the service never reads them. This guards against
    # a regression that would reintroduce the dual-write race.
    payload = SessionCompleteRequest.model_validate(
        {
            "ended_at": (draft_session.started_at + timedelta(minutes=1)).isoformat(),
            "duration_s": 9999,
            "distance_m": 9999,
            "max_speed_mps": 999,
            "avg_speed_mps": 999,
            "elevation_gain_m": 999,
            "elevation_loss_m": 999,
        }
    )
    for banned in (
        "duration_s",
        "distance_m",
        "max_speed_mps",
        "avg_speed_mps",
        "elevation_gain_m",
        "elevation_loss_m",
    ):
        assert banned not in SessionCompleteRequest.model_fields
        assert not hasattr(payload, banned)

    detail = service.complete_session(
        session_id=draft_session.id,
        user_id=user_id,
        completion=payload,
    )

    # Summary values come from the analyzer stub (all zero / None), not the
    # request body.
    assert isinstance(detail, SessionDetail)
    assert detail.session.total_duration_s == 0.0
    assert detail.session.descent_distance_m == 0.0
    assert detail.session.max_speed_mps is None
    assert ride_sessions.analysis_updates[-1]["summary_fields"]["total_duration_s"] == 0.0


# --------------------------------------------------------------------------
# Step 6 — reanalyze_session preserves previously stored preset_overrides.
# --------------------------------------------------------------------------


def test_reanalyze_session_feeds_existing_overrides_into_analyzer() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session

    override_repo = FakeSessionOverrideRepository()
    stored_override = RideSessionOverride(
        session_id=completed_session.id,
        started_at=completed_session.started_at + timedelta(seconds=30),
        ended_at=completed_session.started_at + timedelta(seconds=60),
        motion_state="ignore",
        created_by="user",
    )
    stored_override.id = uuid4()
    override_repo.overrides_by_session[completed_session.id] = [stored_override]

    analyzer = _EmptyAnalysisAnalyzer()
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_override_repository=override_repo,
        session_analyzer=analyzer,
    )

    service.reanalyze_session(
        session_id=completed_session.id,
        user_id=user_id,
    )

    assert len(analyzer.calls) == 1
    analyzer_input = analyzer.calls[0]
    assert analyzer_input.preset_overrides is not None
    assert len(analyzer_input.preset_overrides) == 1
    assert analyzer_input.preset_overrides[0].motion_state == "ignore"
    assert analyzer_input.preset_overrides[0].created_by == "user"


def test_reanalyze_session_without_include_overrides_skips_stored_overrides() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session

    override_repo = FakeSessionOverrideRepository()
    stored_override = RideSessionOverride(
        session_id=completed_session.id,
        started_at=completed_session.started_at,
        ended_at=completed_session.started_at + timedelta(seconds=10),
        motion_state="ignore",
        created_by="user",
    )
    stored_override.id = uuid4()
    override_repo.overrides_by_session[completed_session.id] = [stored_override]

    analyzer = _EmptyAnalysisAnalyzer()
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_override_repository=override_repo,
        session_analyzer=analyzer,
    )

    service.reanalyze_session(
        session_id=completed_session.id,
        user_id=user_id,
        include_overrides=False,
    )

    assert len(analyzer.calls) == 1
    assert analyzer.calls[0].preset_overrides == []


def test_reanalyze_session_on_draft_raises_session_not_yet_completed() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)

    with pytest.raises(SessionNotYetCompletedError):
        service.reanalyze_session(session_id=draft_session.id, user_id=user_id)


# --------------------------------------------------------------------------
# Step 6 — apply_override: created_by='user' is stamped server-side.
# --------------------------------------------------------------------------


def test_apply_override_stamps_created_by_user_server_side() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session

    override_repo = FakeSessionOverrideRepository()
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_override_repository=override_repo,
        session_analyzer=_EmptyAnalysisAnalyzer(),
    )

    service.apply_override(
        session_id=completed_session.id,
        user_id=user_id,
        override_spec=SessionOverrideSpec(
            started_at=completed_session.started_at + timedelta(seconds=5),
            ended_at=completed_session.started_at + timedelta(seconds=25),
            motion_state="ignore",
        ),
    )

    stored = override_repo.overrides_by_session[completed_session.id]
    assert len(stored) == 1
    assert stored[0].created_by == "user"
    assert stored[0].motion_state == "ignore"


def test_apply_override_service_spec_cannot_carry_created_by() -> None:
    # SessionOverrideSpec has no created_by field, so the router can't forward
    # a client-supplied value into the service layer even by accident.
    import dataclasses

    field_names = {f.name for f in dataclasses.fields(SessionOverrideSpec)}
    assert "created_by" not in field_names
    assert field_names == {"started_at", "ended_at", "motion_state"}


# --------------------------------------------------------------------------
# Step 6 — update_session_metadata: conditions-only, no reanalysis.
# --------------------------------------------------------------------------


def test_update_session_metadata_writes_conditions_without_running_analyzer() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session

    analyzer = _EmptyAnalysisAnalyzer()
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_analyzer=analyzer,
    )

    updated = service.update_session_metadata(
        session_id=completed_session.id,
        user_id=user_id,
        update=SessionUpdateRequest(conditions="PACKED"),
    )

    assert updated.conditions == "PACKED"
    # PATCH must be cheap: no analyzer invocation and no new analysis result.
    assert analyzer.calls == []
    assert ride_sessions.analysis_updates == []


def test_update_session_metadata_on_draft_raises_session_not_yet_completed() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    service = _build_service(ride_session_repository=ride_sessions)

    with pytest.raises(SessionNotYetCompletedError):
        service.update_session_metadata(
            session_id=draft_session.id,
            user_id=user_id,
            update=SessionUpdateRequest(conditions="POWDER"),
        )


def test_update_session_metadata_empty_payload_is_noop() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    completed_session.conditions = "GROOMED"
    ride_sessions.sessions[completed_session.id] = completed_session
    service = _build_service(ride_session_repository=ride_sessions)

    service.update_session_metadata(
        session_id=completed_session.id,
        user_id=user_id,
        update=SessionUpdateRequest.model_validate({}),
    )

    assert completed_session.conditions == "GROOMED"


# --------------------------------------------------------------------------
# Step 6 — remove_override ownership rules.
# --------------------------------------------------------------------------


def test_remove_override_rejects_override_not_owned_by_session() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    session_a = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    session_b = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[session_a.id] = session_a
    ride_sessions.sessions[session_b.id] = session_b

    override_repo = FakeSessionOverrideRepository()
    foreign_override = RideSessionOverride(
        session_id=session_b.id,
        started_at=session_b.started_at,
        ended_at=session_b.started_at + timedelta(seconds=10),
        motion_state="ignore",
        created_by="user",
    )
    foreign_override.id = uuid4()
    override_repo.overrides_by_session[session_b.id] = [foreign_override]

    service = _build_service(
        ride_session_repository=ride_sessions,
        session_override_repository=override_repo,
    )

    with pytest.raises(NotFoundError, match=r"Session override not found."):
        service.remove_override(
            session_id=session_a.id,
            user_id=user_id,
            override_id=foreign_override.id,
        )


def test_remove_override_missing_override_raises_not_found() -> None:
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    completed_session = _build_session(user_id=user_id, status=RideSessionStatus.COMPLETED)
    ride_sessions.sessions[completed_session.id] = completed_session
    service = _build_service(ride_session_repository=ride_sessions)

    with pytest.raises(NotFoundError, match=r"Session override not found."):
        service.remove_override(
            session_id=completed_session.id,
            user_id=user_id,
            override_id=uuid4(),
        )


def test_upload_points_batch_rejects_when_session_cap_exceeded(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("MAX_POINTS_PER_SESSION", "3")
    get_settings.cache_clear()
    user_id = uuid4()
    ride_sessions = FakeRideSessionRepository()
    point_repo = FakeSessionPointRepository()
    draft_session = _build_session(user_id=user_id)
    ride_sessions.sessions[draft_session.id] = draft_session
    point_repo.offsets_by_session[draft_session.id] = {0, 1000}
    service = _build_service(
        ride_session_repository=ride_sessions,
        session_point_repository=point_repo,
    )

    with pytest.raises(ValidationError, match=r"Session point limit exceeded."):
        service.upload_points_batch(
            session_id=draft_session.id,
            user_id=user_id,
            points=[
                SessionPointInput(t_offset_ms=2000, latitude=50.0, longitude=-122.0),
                SessionPointInput(t_offset_ms=3000, latitude=50.0, longitude=-122.0),
            ],
        )
    assert point_repo.batches == []
