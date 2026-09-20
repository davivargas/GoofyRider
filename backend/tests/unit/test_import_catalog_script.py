from pathlib import Path

import pytest

import app.scripts.import_catalog as import_catalog_module
from app.scripts.import_catalog import build_argument_parser
from app.scripts.import_catalog import main
from app.services.resort_catalog_import_service import CatalogImportSummary
from app.services.resort_merge_service import MergeSummary
from app.services.resort_source_record_service import RecordUpsertSummary


def test_defaults() -> None:
    args = build_argument_parser().parse_args([])

    assert args.path is None and args.countries is None
    assert not args.merge_only and not args.rematch and not args.force_merge and not args.dry_run


def test_flags_parse() -> None:
    args = build_argument_parser().parse_args(
        [
            "--path",
            "fixtures",
            "--countries",
            "ca, us",
            "--merge-only",
            "--rematch",
            "--force-merge",
            "--dry-run",
        ]
    )

    assert args.path == Path("fixtures")
    assert args.countries == frozenset({"CA", "US"})
    assert args.merge_only and args.rematch and args.force_merge and args.dry_run


def test_merge_only_run_reports_success(monkeypatch: pytest.MonkeyPatch) -> None:
    summary = CatalogImportSummary(
        RecordUpsertSummary(0, 0, 0, 0), 0, 0, 0, MergeSummary(1, 0, 0), None
    )
    monkeypatch.setattr(import_catalog_module, "run", lambda args: summary)

    assert main(["--merge-only"]) == 0
