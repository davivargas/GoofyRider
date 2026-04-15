from __future__ import annotations

from argparse import ArgumentParser
from pathlib import Path

from app.core.database import get_session_local
from app.services.slopes_import_service import SlopesImportService


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
    return parser


def main() -> None:
    args = build_argument_parser().parse_args()
    db = get_session_local()()
    try:
        service = SlopesImportService(db)
        summary = service.import_directory(
            source_dir=args.source_dir,
            user_email=args.user_email,
            dry_run=args.dry_run,
            repair_existing=args.repair_existing,
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
        session_suffix = f", session_id={result.session_id}" if result.session_id is not None else ""
        print(
            f"- {result.file_name}: {result.status} "
            f"({result.resort_name}, {result.point_count} points{session_suffix})"
        )


if __name__ == "__main__":
    main()
