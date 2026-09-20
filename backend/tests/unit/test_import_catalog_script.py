from pathlib import Path

import pytest

from app.scripts.import_catalog import build_argument_parser


def test_defaults() -> None:
    args = build_argument_parser().parse_args([])

    assert args.source == "openskidata"
    assert args.path is None and args.countries is None
    assert not args.merge_only and not args.rematch and not args.force_merge and not args.dry_run


def test_flags_parse() -> None:
    args = build_argument_parser().parse_args(
        [
            "--source",
            "openskidata",
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


def test_invalid_source_is_rejected() -> None:
    with pytest.raises(SystemExit):
        build_argument_parser().parse_args(["--source", "elsewhere"])
