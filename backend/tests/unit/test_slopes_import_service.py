from collections.abc import Callable
from collections.abc import Generator
from datetime import UTC
from datetime import datetime
from pathlib import Path
import textwrap
from uuid import UUID
import zipfile

import pytest
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.database import get_session_local
from app.core.database_safety import assert_safe_test_database_name
from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.ride_session_action import RideSessionAction
from app.models.ride_session_override import RideSessionOverride
from app.models.user import User
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.repositories.user_repository import UserRepository
from app.scripts import import_slopes_sessions
from app.services.slopes_import_service import ParsedSlopesPoint
from app.services.slopes_import_service import SlopesImportService
from app.services.slopes_import_service import build_session_points
from app.services.slopes_import_service import parse_gps_points
from app.services.slopes_import_service import parse_override_segments
from app.services.slopes_import_service import parse_slopes_archive
from app.services.slopes_import_service import parse_slopes_payload

_FIXTURE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "slopes"


def test_parse_override_segments_maps_known_states() -> None:
    segments = parse_override_segments("10-20:ignore;21-30:lift;31-40:run")

    assert [segment.motion_state for segment in segments] == [
        "stopped_idle",
        "lift_uphill",
        "active_descent",
    ]


def test_parse_gps_points_filters_to_record_window_and_maps_motion_states() -> None:
    gps_csv = textwrap.dedent(
        """
        1735905600.000000,49.0,-123.0,1000.0,10.0,2.0,0.5,4.0
        1735905601.000000,49.1,-123.1,1001.0,-1.0,0.0,0.5,4.0
        1735905602.000000,49.2,-123.2,1002.0,200.0,5.0,0.5,4.0
        1735905604.000000,49.4,-123.4,1004.0,180.0,3.0,0.5,4.0
        """
    ).strip()
    record_start = datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC)
    record_end = datetime(2025, 1, 3, 12, 0, 2, tzinfo=UTC)
    overrides = parse_override_segments("1735905600-1735905600:ignore;1735905601-1735905601:lift")

    points = parse_gps_points(
        gps_csv_text=gps_csv,
        record_start=record_start,
        record_end=record_end,
        motion_segments=overrides,
    )

    assert [point.t_offset_ms for point in points] == [0, 1000, 2000]
    assert points[0].motion_state == "stopped_idle"
    assert points[1].motion_state == "lift_uphill"
    assert points[2].motion_state == "stopped_idle"
    assert points[1].heading_deg is None
    assert points[0].distance_delta_m == 0
    assert points[1].distance_delta_m is not None


def test_build_session_points_sets_gps_provider_and_raw_fields() -> None:
    parsed_points = [
        ParsedSlopesPoint(
            t_offset_ms=0,
            recorded_at=datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC),
            latitude=49.0,
            longitude=-123.0,
            altitude_m=1000.0,
            speed_mps=4.0,
            heading_deg=200.0,
            distance_delta_m=0.0,
            motion_state="active_descent",
        )
    ]

    models = build_session_points(
        session_id=UUID("00000000-0000-0000-0000-000000000001"),
        parsed_points=parsed_points,
    )

    assert len(models) == 1
    assert models[0].provider == "gps"
    assert models[0].recorded_at == datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC)
    assert models[0].latitude == 49.0
    assert models[0].longitude == -123.0
    assert models[0].altitude_m == 1000.0
    assert models[0].speed_mps == 4.0
    assert models[0].heading_deg == 200.0


def test_parse_slopes_payload_uses_record_window_and_action_verticals() -> None:
    metadata_xml = textwrap.dedent(
        """
        <Activity
            locationName="Cypress Mountain"
            recordStart="2025-01-03 04:00:00 -0800"
            recordEnd="2025-01-03 04:10:00 -0800"
            distance="600.0"
            topSpeed="12.5"
            overrides="1735905600-1735905601:ignore;1735905602-1735905603:run">
            <actions>
                <Action type="Lift" vertical="120.2" />
                <Action type="Run" vertical="220.8" />
            </actions>
        </Activity>
        """
    ).strip()
    gps_csv = textwrap.dedent(
        """
        1735905600.000000,49.0,-123.0,1000.0,10.0,2.0,0.5,4.0
        1735905602.000000,49.1,-123.1,1005.0,200.0,6.0,0.5,4.0
        1735906201.000000,49.2,-123.2,1008.0,180.0,1.0,0.5,4.0
        """
    ).strip()

    parsed = parse_slopes_payload(
        source_path=Path("sample.slopes"),
        metadata_xml=metadata_xml,
        gps_csv_text=gps_csv,
    )

    assert parsed.resort_name == "Cypress Mountain"
    assert parsed.started_at == datetime(2025, 1, 3, 12, 0, 0, tzinfo=UTC)
    assert parsed.ended_at == datetime(2025, 1, 3, 12, 10, 0, tzinfo=UTC)
    # No statistics are parsed: SessionAnalyzer owns them.
    assert not hasattr(parsed, "duration_s")
    assert not hasattr(parsed, "elevation_gain_m")
    assert [point.motion_state for point in parsed.points] == [
        "stopped_idle",
        "active_descent",
    ]


def test_parse_slopes_archive_reads_zip_entries() -> None:
    archive_path = _FIXTURE_DIR / "grouse_2026-01-18.slopes"

    parsed = parse_slopes_archive(archive_path)

    assert parsed.resort_name == "Grouse Mountain"
    assert parsed.ended_at > parsed.started_at
    assert len(parsed.points) > 0


def test_parse_slopes_archive_falls_back_to_actions_when_overrides_are_sparse() -> None:
    archive_path = _FIXTURE_DIR / "cypress_2026-03-21.slopes"

    parsed = parse_slopes_archive(archive_path)

    assert parsed.resort_name == "Cypress Mountain"
    assert len(parsed.points) > 0
    assert any(point.motion_state == "lift_uphill" for point in parsed.points)
    assert any(point.motion_state == "active_descent" for point in parsed.points)
    assert all(point.motion_state is not None for point in parsed.points)


# --- Database-backed coverage of the create and repair paths ------------------
#
# These need the test database:
#   DATABASE_URL= POSTGRES_DB=goofyrider_test python -m pytest \
#       tests/unit/test_slopes_import_service.py


_TABLES_TO_TRUNCATE = [
    "ride_session_actions",
    "ride_session_overrides",
    "session_points",
    "ride_sessions",
    "resorts",
    "users",
]


def _truncate(session: Session) -> None:
    session.rollback()
    assert_safe_test_database_name(session.execute(text("SELECT current_database()")).scalar_one())
    existing = set(
        session.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        ).scalars()
    )
    for table in _TABLES_TO_TRUNCATE:
        if table in existing:
            session.execute(text(f"TRUNCATE TABLE {table} RESTART IDENTITY CASCADE"))
    session.commit()


@pytest.fixture
def db() -> Generator[Session, None, None]:
    session = get_session_local()()
    try:
        _truncate(session)
        yield session
    finally:
        session.rollback()
        _truncate(session)
        session.close()


@pytest.fixture
def import_service(db: Session) -> SlopesImportService:
    return SlopesImportService(
        user_repository=UserRepository(db),
        resort_repository=ResortRepository(db),
        ride_session_repository=RideSessionRepository(db),
        session_point_repository=SessionPointRepository(db),
    )


@pytest.fixture
def imported_user(db: Session) -> User:
    user = User(
        email="slopes_importer@example.com",
        password_hash="hash",
        display_name="Slopes Importer",
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


@pytest.fixture
def grouse_resort(db: Session) -> Resort:
    resort = Resort(
        name="Grouse Mountain",
        country="Canada",
        region="British Columbia",
        city="North Vancouver",
        latitude=49.38,
        longitude=-123.08,
        elevation_base_m=290,
        elevation_top_m=1231,
    )
    db.add(resort)
    db.commit()
    db.refresh(resort)
    return resort


@pytest.fixture
def grouse_source_dir(tmp_path: Path) -> Path:
    """A small synthetic archive.

    Real `.slopes` fixtures carry thousands of points; parsing them is already
    covered above, and inserting them makes every database test here slow.
    """
    metadata_xml = textwrap.dedent(
        """
        <Activity
            locationName="Grouse Mountain"
            recordStart="2026-01-18 09:00:00 -0800"
            recordEnd="2026-01-18 09:00:04 -0800"
            overrides="1768755600-1768755601:lift;1768755602-1768755604:run">
            <actions>
                <Action type="Lift" vertical="120.0" />
                <Action type="Run" vertical="220.0" />
            </actions>
        </Activity>
        """
    ).strip()
    gps_csv = textwrap.dedent(
        """
        1768755600.000000,49.380,-123.080,900.0,10.0,2.0,0.5,4.0
        1768755601.000000,49.381,-123.081,950.0,20.0,3.0,0.5,4.0
        1768755602.000000,49.382,-123.082,999.0,30.0,9.0,0.5,4.0
        1768755603.000000,49.383,-123.083,940.0,40.0,8.0,0.5,4.0
        1768755604.000000,49.384,-123.084,890.0,50.0,7.0,0.5,4.0
        """
    ).strip()

    archive_path = tmp_path / "grouse_2026-01-18.slopes"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("Metadata.xml", metadata_xml)
        archive.writestr("GPS.csv", gps_csv)
    return tmp_path


def test_import_directory_creates_session_and_points(
    db: Session,
    import_service: SlopesImportService,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
) -> None:
    summary = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )

    assert summary.imported_files == 1
    assert summary.total_points_imported > 0
    session_id = summary.file_results[0].session_id
    assert session_id is not None

    stored = db.get(RideSession, session_id)
    assert stored is not None
    assert stored.user_id == imported_user.id
    assert stored.resort_id == grouse_resort.id
    assert stored.status is RideSessionStatus.COMPLETED
    assert SessionPointRepository(db).count_by_session(session_id) == (
        summary.total_points_imported
    )


def test_import_directory_leaves_statistics_to_the_analyzer(
    db: Session,
    import_service: SlopesImportService,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
) -> None:
    summary = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )
    session_id = summary.file_results[0].session_id
    assert session_id is not None

    stored = db.get(RideSession, session_id)
    assert stored is not None
    # The importer writes no analyzer-owned statistic, including max_speed_mps.
    assert stored.max_speed_mps is None
    assert stored.total_duration_s == 0
    assert stored.descent_distance_m == 0

    # ...but it leaves the session on the reanalysis queue, so the statistics
    # have a path to real values.
    assert stored.processed_by_version is None
    sessions_repo = RideSessionRepository(db)
    queued = sessions_repo.list_needing_reanalysis("any-version", limit=10)
    assert session_id in {queued_session.id for queued_session in queued}


def test_import_directory_skips_an_existing_session_without_repair(
    import_service: SlopesImportService,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
) -> None:
    first = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )
    second = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )

    assert second.imported_files == 0
    assert second.skipped_files == 1
    assert second.file_results[0].status == "skipped_existing"
    assert second.file_results[0].session_id == first.file_results[0].session_id


def test_repair_existing_replaces_points_and_requeues_analysis(
    db: Session,
    import_service: SlopesImportService,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
) -> None:
    first = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )
    session_id = first.file_results[0].session_id
    assert session_id is not None

    # Simulate a session that a previous analyzer run has already processed and
    # written statistics, action spans and derived overrides for.
    stored = db.get(RideSession, session_id)
    assert stored is not None
    stored.processed_by_version = "stale-version"
    stored.processed_at = datetime(2026, 1, 19, tzinfo=UTC)
    stored.total_duration_s = 1234.0
    stored.descent_distance_m = 4321.0
    stored.lift_distance_m = 876.0
    stored.avg_descent_speed_mps = 12.5
    stored.break_count = 7
    stored.max_speed_mps = 99.0
    stored.peak_altitude_m = 1500.0
    db.add(
        RideSessionAction(
            session_id=session_id,
            action_type="run",
            sequence_index=1,
            started_at=datetime(2026, 1, 18, 17, 0, tzinfo=UTC),
            ended_at=datetime(2026, 1, 18, 17, 4, tzinfo=UTC),
            duration_s=240.0,
            distance_m=720.0,
            avg_speed_mps=3.0,
            max_speed_mps=4.5,
            source="live_analyzer",
        )
    )
    # A correction the rider made by hand. Unlike actions and summary numbers
    # it is not derived from the points, so a repair must not discard it.
    db.add(
        RideSessionOverride(
            session_id=session_id,
            started_at=datetime(2026, 1, 18, 17, 0, 1, tzinfo=UTC),
            ended_at=datetime(2026, 1, 18, 17, 0, 3, tzinfo=UTC),
            motion_state="lift",
            created_by="user",
        )
    )
    db.commit()

    repaired = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
        repair_existing=True,
    )

    assert repaired.repaired_files == 1
    assert repaired.file_results[0].session_id == session_id

    db.expire_all()
    stored = db.get(RideSession, session_id)
    assert stored is not None
    # Stale analysis markers are cleared so `reanalyze_sessions` picks it up
    # again instead of leaving the previous numbers next to new points.
    assert stored.processed_by_version is None
    assert stored.processed_at is None
    # ...and so are the numbers and spans themselves, so that a repair that is
    # never followed by a successful analysis cannot serve the previous run's
    # statistics against a different set of points.
    assert stored.total_duration_s == 0
    assert stored.descent_distance_m == 0
    assert stored.lift_distance_m == 0
    assert stored.avg_descent_speed_mps == 0
    assert stored.break_count == 0
    assert stored.max_speed_mps is None
    assert stored.peak_altitude_m is None
    assert stored.actions == []
    # The hand-made override survives: it encodes rider intent against the same
    # record window, and re-analysis feeds it back in as a preset.
    assert [(o.motion_state, o.created_by) for o in stored.overrides] == [("lift", "user")]
    assert SessionPointRepository(db).count_by_session(session_id) == (
        repaired.total_points_imported
    )


def test_repair_existing_dry_run_changes_nothing(
    db: Session,
    import_service: SlopesImportService,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
) -> None:
    first = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
    )
    session_id = first.file_results[0].session_id
    assert session_id is not None
    point_count_before = SessionPointRepository(db).count_by_session(session_id)

    dry_run = import_service.import_directory(
        source_dir=grouse_source_dir,
        user_email=imported_user.email,
        dry_run=True,
        repair_existing=True,
    )

    assert dry_run.repaired_files == 0
    assert dry_run.file_results[0].status == "dry_run_repair_ready"
    assert SessionPointRepository(db).count_by_session(session_id) == point_count_before


# --- The importer script's chained re-analysis --------------------------------
#
# `import_directory` deliberately writes no statistics, so the only thing that
# turns a freshly imported session into one with real numbers is the analysis
# pass `main()` runs afterwards. These exercise that pass against the test
# database.


def _script_argv(source_dir: Path, user_email: str, *extra: str) -> list[str]:
    return [
        "import_slopes_sessions",
        "--source-dir",
        str(source_dir),
        "--user-email",
        user_email,
        *extra,
    ]


@pytest.fixture
def run_script_on_test_db(db: Session, monkeypatch: pytest.MonkeyPatch) -> Callable[..., None]:
    """Run `import_slopes_sessions.main()` against the test-database session.

    `main()` opens and closes its own session; handing it this one keeps the
    script on the test database and lets the assertions read back what it
    committed. `Session.close()` only releases the connection, so the fixture
    session stays usable afterwards.
    """

    def _run(source_dir: Path, user_email: str, *extra: str) -> None:
        monkeypatch.setattr(import_slopes_sessions, "get_session_local", lambda: lambda: db)
        monkeypatch.setattr("sys.argv", _script_argv(source_dir, user_email, *extra))
        import_slopes_sessions.main()

    return _run


@pytest.fixture
def grouse_descent_source_dir(tmp_path: Path) -> Path:
    """An archive long enough for the analyzer to emit a real descent.

    The decoder needs at least `min_run_s` (20 s) of descent dropping at least
    `min_run_drop_m` (15 m), so the four-second archive above would analyze to
    all-zero statistics and prove nothing about the chained analysis.
    """
    # 150 samples at 1 Hz from 09:00:00 -0800, descending 2 m/s at ~9 m/s.
    start_epoch_s = 1768755600
    sample_count = 150
    metadata_xml = textwrap.dedent(
        """
        <Activity
            locationName="Grouse Mountain"
            recordStart="2026-01-18 09:00:00 -0800"
            recordEnd="2026-01-18 09:02:29 -0800" />
        """
    ).strip()
    rows = [
        f"{start_epoch_s + index}.000000,"
        f"{49.380000 - index * 0.00008:.6f},-123.080000,"
        f"{1200.0 - index * 2.0:.1f},180.0,9.0,0.5,4.0"
        for index in range(sample_count)
    ]

    archive_path = tmp_path / "grouse_2026-01-18.slopes"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("Metadata.xml", metadata_xml)
        archive.writestr("GPS.csv", "\n".join(rows))
    return tmp_path


def test_import_script_analyzes_the_sessions_it_imported(
    db: Session,
    imported_user: User,
    grouse_resort: Resort,
    grouse_descent_source_dir: Path,
    run_script_on_test_db: Callable[..., None],
    capsys: pytest.CaptureFixture[str],
) -> None:
    run_script_on_test_db(grouse_descent_source_dir, imported_user.email)

    out = capsys.readouterr().out
    assert "Imported: 1" in out
    assert "Analyzed 1 session(s); analysis failed for 0." in out

    db.expire_all()
    stored = db.query(RideSession).one()
    # The importer writes none of this; only the chained analysis pass does.
    assert stored.processed_by_version == get_settings().session_analyzer_version
    assert stored.processed_at is not None
    assert stored.total_duration_s > 0
    assert stored.descent_duration_s > 0
    assert stored.descent_distance_m > 0
    assert stored.descent_vertical_m > 0
    assert stored.avg_descent_speed_mps > 0
    assert stored.max_speed_mps is not None and stored.max_speed_mps > 0
    assert stored.actions != []


def test_import_script_skip_analysis_leaves_the_session_queued(
    db: Session,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
    run_script_on_test_db: Callable[..., None],
    capsys: pytest.CaptureFixture[str],
) -> None:
    run_script_on_test_db(grouse_source_dir, imported_user.email, "--skip-analysis")

    assert "Analysis skipped." in capsys.readouterr().out
    db.expire_all()
    stored = db.query(RideSession).one()
    assert stored.processed_by_version is None
    assert stored.total_duration_s == 0


class _ExplodingSessionService:
    """An analyzer failure that is not a `ServiceError`."""

    def __init__(self, **kwargs: object) -> None:
        pass

    def reanalyze_stored_session(self, ride_session: RideSession) -> None:
        raise ValueError("analyzer blew up")


def test_import_script_still_reports_the_summary_when_analysis_explodes(
    db: Session,
    imported_user: User,
    grouse_resort: Resort,
    grouse_source_dir: Path,
    run_script_on_test_db: Callable[..., None],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(import_slopes_sessions, "SessionService", _ExplodingSessionService)

    run_script_on_test_db(grouse_source_dir, imported_user.email)

    out = capsys.readouterr().out
    # The operator keeps the record of what was imported and under which ids.
    assert "Imported: 1" in out
    assert "grouse_2026-01-18.slopes: imported" in out
    assert "analysis failed (analyzer blew up)" in out
    assert "Analyzed 0 session(s); analysis failed for 1." in out

    db.expire_all()
    stored = db.query(RideSession).one()
    assert stored.processed_by_version is None
