"""Import Slopes `.slopes` archives as ride sessions, then analyze them.

The importer only writes the session shell (user, resort, record window) and
the raw GPS points. Per-session statistics belong to `SessionAnalyzer`, so a
freshly written session starts with `processed_by_version` unset. This script
therefore runs analysis for every session it imported or repaired before it
exits, and a session left unanalyzed (for example because analysis failed, or
because the import was interrupted) is still picked up by a later
`python -m app.scripts.reanalyze_sessions` run.

Usage (from backend/):
    python -m app.scripts.import_slopes_sessions \
        --source-dir ~/slopes --user-email rider@example.com
    python -m app.scripts.import_slopes_sessions ... --dry-run
    python -m app.scripts.import_slopes_sessions ... --repair-existing
    python -m app.scripts.import_slopes_sessions ... --skip-analysis
"""

from __future__ import annotations

from argparse import ArgumentParser
from pathlib import Path
import uuid

from sqlalchemy.orm import Session

from app.core.database import get_session_local
from app.core.dependencies.sessions import get_session_analyzer
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_override_repository import SessionOverrideRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.repositories.user_repository import UserRepository
from app.services.exceptions import ServiceError
from app.services.session_service import SessionService
from app.services.slopes_import_service import SlopesImportService
from app.services.slopes_import_service import SlopesImportSummary

_ANALYZABLE_STATUSES = frozenset({"imported", "repaired"})


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="Import Slopes .slopes archives into ride_sessions.")
    parser.add_argument(
        "--source-dir",
        required=True,
        type=Path,
        help="Directory containing .slopes files.",
    )
    parser.add_argument(
        "--user-email",
        required=True,
        help="Existing backend user email that will own the imported sessions.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse and validate archives without writing any sessions or points.",
    )
    parser.add_argument(
        "--repair-existing",
        action="store_true",
        help="Repair matching existing imported sessions instead of skipping them.",
    )
    parser.add_argument(
        "--skip-analysis",
        action="store_true",
        help=(
            "Import without running the analyzer. The sessions stay eligible for "
            "`python -m app.scripts.reanalyze_sessions`, which must then be run "
            "before their statistics are meaningful."
        ),
    )
    return parser


def _analyzable_session_ids(summary: SlopesImportSummary) -> list[uuid.UUID]:
    return [
        result.session_id
        for result in summary.file_results
        if result.session_id is not None and result.status in _ANALYZABLE_STATUSES
    ]


def analyze_imported_sessions(
    db: Session,
    session_ids: list[uuid.UUID],
) -> tuple[int, int]:
    """Run the analyzer over freshly imported sessions. Returns (done, failed)."""
    sessions_repo = RideSessionRepository(db)
    service = SessionService(
        ride_session_repository=sessions_repo,
        resort_repository=ResortRepository(db),
        session_point_repository=SessionPointRepository(db),
        session_override_repository=SessionOverrideRepository(db),
        session_analyzer=get_session_analyzer(),
        resort_lift_repository=ResortLiftRepository(db),
    )

    done = failed = 0
    for session_id in session_ids:
        ride_session = sessions_repo.get_detail_with_actions(session_id)
        if ride_session is None:
            failed += 1
            print(f"- {session_id}: analysis skipped (session not found)")
            continue
        try:
            service.reanalyze_stored_session(ride_session)
            done += 1
        except ServiceError as exc:
            sessions_repo.rollback()
            failed += 1
            print(f"- {session_id}: analysis failed ({exc})")
    return done, failed


def main() -> None:
    args = build_argument_parser().parse_args()
    db = get_session_local()()
    analyzed = analysis_failed = 0
    try:
        service = SlopesImportService(
            user_repository=UserRepository(db),
            resort_repository=ResortRepository(db),
            ride_session_repository=RideSessionRepository(db),
            session_point_repository=SessionPointRepository(db),
        )
        summary = service.import_directory(
            source_dir=args.source_dir,
            user_email=args.user_email,
            dry_run=args.dry_run,
            repair_existing=args.repair_existing,
        )
        if not args.dry_run and not args.skip_analysis:
            analyzed, analysis_failed = analyze_imported_sessions(
                db, _analyzable_session_ids(summary)
            )
    except ValueError as exc:
        db.rollback()
        raise SystemExit(str(exc)) from exc
    finally:
        db.close()

    mode = "Dry run complete" if args.dry_run else "Import complete"
    print(
        f"{mode}. Files: {summary.discovered_files}, "
        f"Imported: {summary.imported_files}, "
        f"Repaired: {summary.repaired_files}, "
        f"Skipped: {summary.skipped_files}, "
        f"Points seen: {summary.total_points_seen}, "
        f"Points imported: {summary.total_points_imported}"
    )
    for result in summary.file_results:
        session_suffix = (
            f", session_id={result.session_id}" if result.session_id is not None else ""
        )
        print(
            f"- {result.file_name}: {result.status} "
            f"({result.resort_name}, {result.point_count} points{session_suffix})"
        )

    if args.dry_run:
        return
    if args.skip_analysis:
        print(
            "Analysis skipped. Run `python -m app.scripts.reanalyze_sessions` to "
            "compute statistics for the imported sessions."
        )
        return
    print(f"Analyzed {analyzed} session(s); analysis failed for {analysis_failed}.")
    if analysis_failed:
        print("Re-run `python -m app.scripts.reanalyze_sessions` to retry the failures.")


if __name__ == "__main__":
    main()
