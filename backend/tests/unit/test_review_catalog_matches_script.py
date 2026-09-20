import uuid

import pytest

from app.scripts.review_catalog_matches import build_argument_parser


def test_list_defaults_to_all_sources() -> None:
    args = build_argument_parser().parse_args(["list"])
    assert args.command == "list" and args.source is None


def test_link_parses_uuid() -> None:
    resort_id = uuid.uuid4()
    args = build_argument_parser().parse_args(["link", "openskidata", "osd-x", str(resort_id)])
    assert (args.command, args.source, args.external_id, args.resort_id) == (
        "link",
        "openskidata",
        "osd-x",
        resort_id,
    )


def test_link_rejects_bad_uuid() -> None:
    with pytest.raises(SystemExit):
        build_argument_parser().parse_args(["link", "openskidata", "osd-x", "not-a-uuid"])


def test_reject_and_create() -> None:
    assert build_argument_parser().parse_args(["reject", "ski_api", "slug"]).command == "reject"
    assert build_argument_parser().parse_args(["create", "ski_api", "slug"]).command == "create"
