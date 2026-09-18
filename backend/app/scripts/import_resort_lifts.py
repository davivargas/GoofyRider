"""Fill resort_lifts from OpenStreetMap for one resort or for a user's favourites.

Usage (from backend/):
    python -m app.scripts.import_resort_lifts --resort "Grouse Mountain" [--radius-m 6000]
    python -m app.scripts.import_resort_lifts --all-favourites --user-email you@example.com
"""

from __future__ import annotations

from argparse import ArgumentParser
import uuid

from app.core.config import get_settings
from app.core.database import get_session_local
from app.models.resort import Resort
from app.repositories.favorite_resort_repository import FavoriteResortRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.user_repository import UserRepository
from app.services.exceptions import ServiceError
from app.services.osm_lift_catalog_service import OsmLiftCatalogService


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="Import lift lines from OpenStreetMap into resort_lifts.")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--resort", help="Resort name (case-insensitive) or resort id.")
    target.add_argument(
        "--all-favourites", action="store_true", help="Every favourite resort of --user-email."
    )
    parser.add_argument("--user-email", help="Required with --all-favourites.")
    parser.add_argument(
        "--radius-m", type=int, default=6000, help="Search radius around the resort centre."
    )
    return parser


def main() -> None:
    args = build_argument_parser().parse_args()
    if args.all_favourites and not args.user_email:
        raise SystemExit("--all-favourites requires --user-email")
    settings = get_settings()
    db = get_session_local()()
    try:
        resorts_repo = ResortRepository(db)
        lifts_repo = ResortLiftRepository(db)
        targets: list[Resort] = []
        if args.resort:
            resort = None
            try:
                resort = resorts_repo.get_by_id(uuid.UUID(args.resort))
            except ValueError:
                resort = resorts_repo.get_by_name(args.resort)
            if resort is None:
                raise SystemExit(f"Resort not found: {args.resort}")
            targets.append(resort)
        else:
            user = UserRepository(db).get_by_email(args.user_email)
            if user is None:
                raise SystemExit(f"User not found: {args.user_email}")
            targets.extend(FavoriteResortRepository(db).list_by_user_id(user.id))
        service = OsmLiftCatalogService(
            base_url=settings.overpass_base_url, timeout_seconds=settings.overpass_timeout_seconds
        )
        for resort in targets:
            try:
                count = service.import_for_resort(resort, lifts_repo, radius_m=args.radius_m)
            except ServiceError as exc:
                db.rollback()
                print(f"- {resort.name}: failed ({exc})")
                continue
            print(f"- {resort.name}: {count} lifts upserted")
    finally:
        db.close()


if __name__ == "__main__":
    main()
