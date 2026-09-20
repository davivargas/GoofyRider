"""Resolve pending catalog matches.

Usage (from backend/):
    python -m app.scripts.review_catalog_matches list [--source openskidata|ski_api] [--legacy]
    python -m app.scripts.review_catalog_matches link openskidata <external_id> <resort_uuid>
    python -m app.scripts.review_catalog_matches reject openskidata <external_id>
    python -m app.scripts.review_catalog_matches create openskidata <external_id>

`link`, `reject` and `create` act on records awaiting review, which only OpenSkiData
produces. `ski_api` stays a valid --source for `list` because migration 0016 left legacy
`ski_api` records behind; `list --legacy` is how you see them.

Lifts for a resort linked through the review script are written by the next `import_catalog`
run. (Spec 7.1 says each resolution writes that ski area's lifts; this deviates on purpose.)
"""

from __future__ import annotations

from argparse import ArgumentParser
from argparse import Namespace
from collections.abc import Sequence
import sys
import uuid

from app.core.database import get_session_local
from app.repositories.resort_field_override_repository import ResortFieldOverrideRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.resort_source_record_repository import ResortSourceRecordRepository
from app.services.exceptions import ServiceError
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_review_service import ResortReviewService

SOURCES = ("openskidata", "ski_api")


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="List or resolve pending catalog matches.")
    commands = parser.add_subparsers(dest="command", required=True)

    list_cmd = commands.add_parser("list", help="Show records waiting for review.")
    list_cmd.add_argument("--source", choices=SOURCES, default=None)
    list_cmd.add_argument(
        "--legacy",
        action="store_true",
        help="Show legacy records with match candidates instead of pending ones.",
    )

    link_cmd = commands.add_parser("link", help="Link a record to an existing resort.")
    link_cmd.add_argument("source", choices=SOURCES)
    link_cmd.add_argument("external_id")
    link_cmd.add_argument("resort_id", type=uuid.UUID)

    reject_cmd = commands.add_parser("reject", help="Mark a record as not a resort we track.")
    reject_cmd.add_argument("source", choices=SOURCES)
    reject_cmd.add_argument("external_id")

    create_cmd = commands.add_parser("create", help="Create a resort from a record.")
    create_cmd.add_argument("source", choices=SOURCES)
    create_cmd.add_argument("external_id")
    return parser


def run(args: Namespace) -> int:
    db = get_session_local()()
    try:
        resorts = ResortRepository(db)
        records = ResortSourceRecordRepository(db)
        lifts = ResortLiftRepository(db)
        service = ResortReviewService(
            resort_repository=resorts,
            record_repository=records,
            merge_service=ResortMergeService(
                resorts, records, ResortFieldOverrideRepository(db), lifts
            ),
        )
        if args.command == "list":
            items = service.list_legacy() if args.legacy else service.list_pending(args.source)
            if not items:
                print(
                    "No legacy records with candidates."
                    if args.legacy
                    else "No records pending review."
                )
            for item in items:
                print(f"{item.source} {item.external_id} — {item.name or '(no name)'}")
                for candidate in item.candidates:
                    print(
                        f"    {candidate.get('score')}  {candidate.get('name')}  "
                        f"{candidate.get('resort_id')}  {candidate.get('distance_m')} m"
                    )
                    if args.legacy:
                        print(
                            f"        external_id={candidate.get('external_id')}  "
                            f"linked_resort_id={candidate.get('linked_resort_id')}"
                        )
            return 0
        if args.command == "link":
            service.link(args.source, args.external_id, args.resort_id)
            print(f"Linked {args.source}:{args.external_id} to {args.resort_id}")
        elif args.command == "reject":
            service.reject(args.source, args.external_id)
            print(f"Rejected {args.source}:{args.external_id}")
        else:
            resort_id = service.create(args.source, args.external_id)
            print(f"Created resort {resort_id} from {args.source}:{args.external_id}")
        return 0
    finally:
        db.close()


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    try:
        return run(args)
    except ServiceError as exc:
        print(f"Review failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
