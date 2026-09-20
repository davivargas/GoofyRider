from pathlib import Path

import pytest

from app.core.config import AppSettings
import app.scripts.import_catalog as import_catalog_module
from app.scripts.import_catalog import build_argument_parser
from app.scripts.import_catalog import main


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


def test_ski_api_source_without_key_exits_with_code_2(monkeypatch: pytest.MonkeyPatch) -> None:
    # Patch the settings object, not the env: a developer .env holding a real key must never
    # let this test fall through the guard and reach the live API.
    keyless = AppSettings(jwt_secret_key="k" * 32, ski_api_key=None)
    monkeypatch.setattr(import_catalog_module, "get_settings", lambda: keyless)

    assert main(["--source", "ski_api"]) == 2


def test_merge_only_skips_the_ski_api_key_guard(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SKI_API_KEY", raising=False)
    monkeypatch.setattr(import_catalog_module, "run", lambda args: [])

    assert main(["--source", "all", "--merge-only"]) == 0
