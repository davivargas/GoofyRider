"""Re-run the analyzer over stored sessions processed by an older analyzer version.

Usage (from backend/):
    python -m app.scripts.reanalyze_sessions [--batch-size 50] [--dry-run]
"""

from __future__ import annotations

from argparse import ArgumentParser

from app.core.config import get_settings
from app.core.database import get_session_local
from app.core.dependencies.sessions import get_session_analyzer
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_override_repository import SessionOverrideRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.services.exceptions import ServiceError
from app.services.session_service import SessionService


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(
        description="Re-analyze sessions not processed by the current analyzer version."
    )
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument(
        "--dry-run", action="store_true", help="Count and list sessions without changing them."
    )
    return parser


def main() -> None:
    args = build_argument_parser().parse_args()
    version = get_settings().session_analyzer_version
    db = get_session_local()()
    try:
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
        while True:
            batch = sessions_repo.list_needing_reanalysis(version, limit=args.batch_size)
            if not batch:
                break
            if args.dry_run:
                for session in batch:
                    print(f"- {session.id} ({session.processed_by_version or 'never'})")
                done += len(batch)
                break
            for session in batch:
                try:
                    service.reanalyze_stored_session(session)
                    done += 1
                except ServiceError as exc:
                    db.rollback()
                    failed += 1
                    print(f"- {session.id}: failed ({exc})")
    finally:
        db.close()
    print(
        f"{'Would re-analyze' if args.dry_run else 'Re-analyzed'} {done} session(s); failed {failed}; version {version}"
    )


if __name__ == "__main__":
    main()
