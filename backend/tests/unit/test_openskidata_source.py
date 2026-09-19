from datetime import UTC
from datetime import datetime
from pathlib import Path

import httpx
import pytest

from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.openskidata_source import OpenSkiDataSource

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "openskidata"


def test_local_dir_reads_metadata_and_filters_ski_areas() -> None:
    with OpenSkiDataSource(
        base_url="https://unused.test", timeout_seconds=5, local_dir=FIXTURES
    ) as source:
        assert source.snapshot_built_at() == datetime(2026, 9, 18, 23, 29, 43, 282000, tzinfo=UTC)
        ids = [record.external_id for record in source.iter_ski_areas()]

    assert ids == ["osd-cypress", "osd-grouse", "osd-grouse-us", "osd-seymour"]


def test_ski_area_record_carries_whole_feature_and_hash() -> None:
    with OpenSkiDataSource(
        base_url="https://unused.test", timeout_seconds=5, local_dir=FIXTURES
    ) as source:
        grouse = next(r for r in source.iter_ski_areas() if r.external_id == "osd-grouse")

    assert grouse.source == "openskidata"
    assert grouse.payload["geometry"]["type"] == "Polygon"
    assert grouse.payload["properties"]["name"] == "Grouse Mountain"
    assert len(grouse.content_hash) == 64
    assert grouse.snapshot_built_at == datetime(2026, 9, 18, 23, 29, 43, 282000, tzinfo=UTC)


def test_iter_lifts_skips_abandoned_and_unsupported() -> None:
    with OpenSkiDataSource(
        base_url="https://unused.test", timeout_seconds=5, local_dir=FIXTURES
    ) as source:
        list(source.iter_ski_areas())
        track_ids = sorted(lift.external_track_id for lift in source.iter_lifts())

    assert "osm:way:1004" not in track_ids  # abandoned
    assert "osm:way:4001" not in track_ids  # funicular
    assert track_ids == sorted(
        [
            "osm:way:1001",
            "osm:way:1002",
            "osm:way:1003",
            "osm:way:2001",
            "osm:way:2002",
            "osm:way:3001",
            "osm:way:3002",
            "osm:way:5001",
        ]
    )


def test_country_filter_applies_to_ski_areas_and_their_lifts() -> None:
    with OpenSkiDataSource(
        base_url="https://unused.test",
        timeout_seconds=5,
        local_dir=FIXTURES,
        countries=frozenset({"US"}),
    ) as source:
        ids = [record.external_id for record in source.iter_ski_areas()]
        lifts = list(source.iter_lifts())

    assert ids == ["osd-grouse-us"]
    assert lifts == []


def test_download_streams_files_and_maps_transport_errors(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        name = request.url.path.rsplit("/", 1)[-1]
        if name == "metadata.json":
            return httpx.Response(200, content=(FIXTURES / "metadata.json").read_bytes())
        if name == "ski_areas.geojson":
            return httpx.Response(200, content=(FIXTURES / "ski_areas.geojson").read_bytes())
        return httpx.Response(503)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    with OpenSkiDataSource(base_url="https://osd.test", timeout_seconds=5, client=client) as source:
        assert source.snapshot_built_at() is not None
        assert len(list(source.iter_ski_areas())) == 4
        with pytest.raises(ServiceUnavailableError):
            list(source.iter_lifts())


def test_invalid_json_becomes_validation_error(tmp_path: Path) -> None:
    (tmp_path / "metadata.json").write_text("{}", encoding="utf-8")
    (tmp_path / "ski_areas.geojson").write_text(
        '{"type": "FeatureCollection", "features": [', encoding="utf-8"
    )

    with OpenSkiDataSource(
        base_url="https://unused.test", timeout_seconds=5, local_dir=tmp_path
    ) as source:
        assert source.snapshot_built_at() is None
        with pytest.raises(ValidationError):
            list(source.iter_ski_areas())
