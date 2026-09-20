"""Import the resort catalog from OpenSkiData, SkiAPI, or both.

Usage (from backend/):
    python -m app.scripts.import_catalog
    python -m app.scripts.import_catalog --path /data/openskidata --countries CA,US
    python -m app.scripts.import_catalog --source ski_api
    python -m app.scripts.import_catalog --source all
    python -m app.scripts.import_catalog --merge-only
"""

from __future__ import annotations

from argparse import ArgumentParser
from argparse import Namespace
from collections.abc import Sequence
from pathlib import Path
import sys

from app.core.config import get_settings
from app.core.database import get_session_local
from app.repositories.resort_field_override_repository import ResortFieldOverrideRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.resort_source_record_repository import ResortSourceRecordRepository
from app.services.exceptions import ServiceError
from app.services.openskidata_source import OpenSkiDataSource
from app.services.resort_catalog_import_service import CatalogImportOptions
from app.services.resort_catalog_import_service import CatalogImportSummary
from app.services.resort_catalog_import_service import ResortCatalogImportService
from app.services.resort_lift_sync_service import LiftSyncSummary
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_source_record_service import RecordUpsertSummary
from app.services.resort_source_record_service import ResortSourceRecordService
from app.services.ski_api_resort_source import SkiApiResortSource


def _countries(value: str) -> frozenset[str]:
    codes = {part.strip().upper() for part in value.split(",") if part.strip()}
    if not codes:
        raise ValueError("at least one country code is required")
    return frozenset(codes)


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="Import the resort catalog into the database.")
    parser.add_argument(
        "--source", choices=("openskidata", "ski_api", "all"), default="openskidata"
    )
    parser.add_argument(
        "--path", type=Path, default=None, help="Directory with a downloaded snapshot."
    )
    parser.add_argument("--countries", type=_countries, default=None, help="ISO codes, e.g. CA,US.")
    parser.add_argument(
        "--merge-only", action="store_true", help="Re-run the merge from stored records."
    )
    parser.add_argument("--rematch", action="store_true", help="Re-evaluate auto links.")
    parser.add_argument(
        "--force-merge", action="store_true", help="Merge every resort, not only stale ones."
    )
    parser.add_argument("--dry-run", action="store_true", help="Roll back instead of committing.")
    return parser


def run(args: Namespace) -> list[tuple[str, CatalogImportSummary]]:
    settings = get_settings()
    db = get_session_local()()
    try:
        resorts = ResortRepository(db)
        records = ResortSourceRecordRepository(db)
        overrides = ResortFieldOverrideRepository(db)
        lifts = ResortLiftRepository(db)
        merge = ResortMergeService(resorts, records, overrides, lifts)
        importer = ResortCatalogImportService(
            resort_repository=resorts,
            record_repository=records,
            override_repository=overrides,
            lift_repository=lifts,
            record_service=ResortSourceRecordService(records),
            merge_service=merge,
            lift_sync_service=ResortLiftSyncService(records, lifts),
        )
        options = CatalogImportOptions(rematch=args.rematch, dry_run=args.dry_run)
        if args.merge_only:
            merge_summary = merge.merge_stale(force=args.force_merge)
            if args.dry_run:
                resorts.rollback()
            else:
                resorts.commit()
            return [
                (
                    "merge",
                    CatalogImportSummary(
                        RecordUpsertSummary(0, 0, 0, 0), 0, 0, 0, merge_summary, None
                    ),
                )
            ]
        summaries: list[tuple[str, CatalogImportSummary]] = []
        if args.source in ("openskidata", "all"):
            with OpenSkiDataSource(
                base_url=settings.openskidata_base_url,
                timeout_seconds=settings.openskidata_timeout_seconds,
                local_dir=args.path,
                countries=args.countries,
            ) as source:
                summary = importer.import_openskidata(source, options)
            if args.force_merge and not args.dry_run:
                forced = merge.merge_stale(force=True)
                resorts.commit()
                summary = CatalogImportSummary(
                    summary.records,
                    summary.linked_auto,
                    summary.linked_primary,
                    summary.pending_review,
                    forced,
                    summary.lifts,
                )
            summaries.append(("openskidata", summary))
        if args.source in ("ski_api", "all"):
            ski_api = SkiApiResortSource(
                base_url=settings.ski_api_base_url,
                api_key=settings.ski_api_key,
                api_host=settings.ski_api_host,
                page_size=settings.ski_api_page_size,
                timeout_seconds=settings.ski_api_timeout_seconds,
            )
            ski_summary = importer.import_ski_api(ski_api, options)
            summaries.append(("ski_api", ski_summary))
        return summaries
    finally:
        db.close()


def _print_summary(name: str, summary: CatalogImportSummary) -> None:
    r = summary.records
    print(
        f"[{name}] Records: "
        f"created={r.created} updated={r.updated} unchanged={r.unchanged} missing={r.marked_missing}"
    )
    print(
        f"[{name}] Links: auto={summary.linked_auto} primary={summary.linked_primary} "
        f"pending_review={summary.pending_review}"
    )
    m = summary.merge
    print(
        f"[{name}] Merge: merged={m.merged_count} changed={m.changed_count} "
        f"deactivated={m.deactivated_count}"
    )
    lifts: LiftSyncSummary | None = summary.lifts
    if lifts is not None:
        print(
            f"[{name}] Lifts: upserted={lifts.upserted} deleted={lifts.deleted} "
            f"skipped_unlinked={lifts.skipped_unlinked}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    if args.source in ("ski_api", "all") and not args.merge_only and not get_settings().ski_api_key:
        print("SKI_API_KEY is not set; cannot import from SkiAPI.", file=sys.stderr)
        return 2
    try:
        summaries = run(args)
    except ServiceError as exc:
        print(f"Catalog import failed: {exc}", file=sys.stderr)
        return 1
    for name, summary in summaries:
        _print_summary(name, summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
