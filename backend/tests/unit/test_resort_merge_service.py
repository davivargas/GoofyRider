from datetime import UTC
from datetime import datetime
from typing import Any
import uuid

import pytest

from app.models.resort import Resort
from app.models.resort_field_override import ResortFieldOverride
from app.models.resort_lift import ResortLift
from app.models.resort_source_record import ResortSourceRecord
from app.services.catalog_types import SOURCE_OPENSKIDATA
from app.services.catalog_types import SOURCE_SKI_API
from app.services.catalog_types import SourceResortView
from app.services.exceptions import ValidationError
from app.services.resort_merge_service import LinkedView
from app.services.resort_merge_service import MergeResult
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_merge_service import compute_merge
from app.services.resort_merge_service import view_for_record

NOW = datetime(2026, 9, 19, 12, 0, tzinfo=UTC)


def _view(source: str = SOURCE_OPENSKIDATA, **overrides: Any) -> SourceResortView:
    base: dict[str, Any] = {
        "source": source,
        "name": "Grouse Mountain",
        "latitude": 49.38,
        "longitude": -123.08,
        "boundary": None,
        "bbox": None,
        "country": "Canada",
        "country_code": "CA",
        "region": "British Columbia",
        "region_code": "CA-BC",
        "city": "North Vancouver",
        "elevation_base_m": 880,
        "elevation_top_m": 1250,
        "lift_envelope": (895, 1231),
        "status": "operating",
        "activities": ("downhill",),
    }
    base.update(overrides)
    return SourceResortView(**base)


def _merge(
    views: list[LinkedView],
    overrides: dict[str, Any] | None = None,
    envelope: tuple[int, int] | None = None,
) -> MergeResult:
    return compute_merge(
        current_name="Old Name",
        current_country="Old Country",
        current_region="Old Region",
        views=views,
        overrides=overrides or {},
        lift_envelope=envelope,
    )


def test_openskidata_wins_and_ski_api_supplies_alias() -> None:
    result = _merge(
        [
            LinkedView(_view(), missing=False),
            LinkedView(
                _view(SOURCE_SKI_API, name="Grouse Mtn", city="Vancouver", elevation_top_m=1300),
                missing=False,
            ),
        ]
    )

    assert result.name == "Grouse Mountain" and result.provenance["name"] == "openskidata"
    assert result.city == "North Vancouver" and result.provenance["city"] == "openskidata"
    assert result.elevation_top_m == 1250
    assert result.name_aliases == ("Grouse Mtn",)
    assert result.is_active is True


def test_failed_check_falls_through_to_next_source() -> None:
    result = _merge(
        [
            LinkedView(_view(elevation_base_m=1300, elevation_top_m=1250), missing=False),
            LinkedView(
                _view(SOURCE_SKI_API, elevation_base_m=900, elevation_top_m=1240), missing=False
            ),
        ]
    )

    assert (result.elevation_base_m, result.elevation_top_m) == (900, 1240)
    assert result.provenance["elevation_top_m"] == "ski_api"
    assert result.provenance["elevation_base_m"] == "ski_api"


def test_elevation_falls_back_to_lift_envelope_when_every_source_fails() -> None:
    result = _merge(
        [LinkedView(_view(elevation_base_m=100, elevation_top_m=5000), missing=False)],
        envelope=(895, 1231),
    )

    assert (result.elevation_base_m, result.elevation_top_m) == (895, 1231)
    assert result.provenance["elevation_top_m"] == "derived_lifts"


def test_imported_lift_envelope_beats_statistics_envelope() -> None:
    result = _merge(
        [
            LinkedView(
                _view(elevation_base_m=880, elevation_top_m=1250, lift_envelope=(895, 1231)),
                missing=False,
            )
        ],
        envelope=(1500, 2000),
    )

    assert (result.elevation_base_m, result.elevation_top_m) == (1500, 2000)


def test_override_beats_every_source() -> None:
    result = _merge(
        [LinkedView(_view(), missing=False)],
        overrides={"city": "Grouse Village", "is_active": False},
    )

    assert result.city == "Grouse Village" and result.provenance["city"] == "manual"
    assert result.is_active is False and result.provenance["is_active"] == "manual"


def test_not_null_columns_keep_unvalidated_or_current_values() -> None:
    result = _merge([LinkedView(_view(name="x" * 130, country=None, region=None), missing=False)])

    # The `unvalidated` fallback routes past check_name, so the clamp is what keeps the
    # value inside resorts.name (String(120)).
    assert result.name == "x" * 120 and result.provenance["name"] == "unvalidated"
    assert result.country == "Old Country" and result.provenance["country"] == "none"
    assert result.region == "Old Region"


def test_overlong_source_text_is_clamped_to_its_column_length() -> None:
    result = _merge(
        [
            LinkedView(
                _view(
                    name="n" * 200,
                    country="c" * 200,
                    region="r" * 200,
                    city="y" * 200,
                    region_code="g" * 40,
                ),
                missing=False,
            )
        ]
    )

    assert len(result.name) == 120 and result.name == "n" * 120
    assert len(result.country) == 100 and len(result.region) == 100
    assert result.city is not None and len(result.city) == 100
    assert result.region_code is not None and len(result.region_code) == 10


def test_overlong_text_override_is_clamped() -> None:
    result = _merge([LinkedView(_view(), missing=False)], {"name": "z" * 200})

    assert result.name == "z" * 120 and result.provenance["name"] == "manual"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("elevation_top_m", "high"),
        ("elevation_base_m", 12.5),
        ("latitude", "north"),
        ("longitude", None),
        ("is_active", "yes"),
        ("city", 7),
    ],
)
def test_malformed_override_raises_validation_error(field: str, value: Any) -> None:
    with pytest.raises(ValidationError, match=f"Invalid override {field!r}"):
        _merge([LinkedView(_view(), missing=False)], {field: value})


def test_coordinates_outside_boundary_fall_through() -> None:
    square = {
        "type": "Polygon",
        "coordinates": [
            [[-123.1, 49.3], [-123.0, 49.3], [-123.0, 49.4], [-123.1, 49.4], [-123.1, 49.3]]
        ],
    }
    result = _merge(
        [
            LinkedView(
                _view(
                    latitude=49.9,
                    longitude=-123.05,
                    boundary=square,
                    bbox=(49.3, -123.1, 49.4, -123.0),
                ),
                missing=False,
            ),
            LinkedView(_view(SOURCE_SKI_API, latitude=49.35, longitude=-123.05), missing=False),
        ]
    )

    assert (result.latitude, result.longitude) == (49.35, -123.05)
    assert result.provenance["latitude"] == "ski_api"
    assert result.boundary == square


def test_missing_or_non_operating_records_deactivate() -> None:
    assert _merge([LinkedView(_view(), missing=True)]).is_active is False
    assert _merge([LinkedView(_view(status="abandoned"), missing=False)]).is_active is False
    assert _merge([LinkedView(_view(status=None), missing=False)]).is_active is True
    assert _merge([LinkedView(_view(SOURCE_SKI_API, status=None), missing=False)]).is_active is True
    assert _merge([]).is_active is False


def test_merge_is_order_independent() -> None:
    a = LinkedView(_view(), missing=False)
    b = LinkedView(_view(SOURCE_SKI_API, name="Grouse Mtn"), missing=False)

    assert _merge([a, b]) == _merge([b, a])


def test_view_for_record_raises_validation_error_for_unknown_source() -> None:
    record = ResortSourceRecord(
        source="unknown",
        external_id="x",
        payload={},
        content_hash="h",
        fetched_at=NOW,
        match_status="linked",
    )

    with pytest.raises(ValidationError):
        view_for_record(record)


class FakeResortRepository:
    def __init__(self, resorts: list[Resort]) -> None:
        self.resorts = resorts
        self.committed = 0

    def list_stale_for_merge(self) -> list[Resort]:
        return [r for r in self.resorts if r.last_merged_at is None]

    def list_all_for_matching(self) -> list[Resort]:
        return list(self.resorts)

    def flush(self) -> None:
        pass

    def commit(self) -> None:
        self.committed += 1


class FakeRecordRepository:
    def __init__(self, records: list[ResortSourceRecord]) -> None:
        self.records = records

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortSourceRecord]:
        return [r for r in self.records if r.resort_id == resort_id]


class FakeOverrideRepository:
    def __init__(self, overrides: list[ResortFieldOverride]) -> None:
        self.overrides = overrides

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortFieldOverride]:
        return [o for o in self.overrides if o.resort_id == resort_id]


class FakeLiftRepository:
    def __init__(self, lifts: list[ResortLift]) -> None:
        self.lifts = lifts

    def list_by_resort(self, resort_id: uuid.UUID) -> list[ResortLift]:
        return [lift for lift in self.lifts if lift.resort_id == resort_id]


def _grouse_feature() -> dict[str, Any]:
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [-123.08, 49.38]},
        "properties": {
            "type": "skiArea",
            "id": "osd-grouse",
            "name": "Grouse Mountain",
            "activities": ["downhill"],
            "status": "operating",
            "sources": [],
            "statistics": {
                "minElevation": 880,
                "maxElevation": 1250,
                "runs": {"byActivity": {}},
                "lifts": {"byType": {}},
            },
            "places": [
                {
                    "iso3166_1Alpha2": "CA",
                    "iso3166_2": "CA-BC",
                    "localized": {
                        "en": {
                            "country": "Canada",
                            "region": "British Columbia",
                            "locality": "North Vancouver",
                        }
                    },
                }
            ],
        },
    }


def test_service_merges_stale_resorts_and_is_idempotent() -> None:
    resort = Resort(
        id=uuid.uuid4(),
        name="Old",
        country="Old",
        region="Old",
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    record = ResortSourceRecord(
        source=SOURCE_OPENSKIDATA,
        external_id="osd-grouse",
        payload=_grouse_feature(),
        content_hash="h",
        fetched_at=NOW,
        resort_id=resort.id,
        match_status="linked",
        match_method="primary",
    )
    lifts = [
        ResortLift(
            resort_id=resort.id,
            name="A",
            base_altitude_m=900.0,
            top_altitude_m=1200.0,
            source="openskidata",
        ),
        ResortLift(
            resort_id=resort.id,
            name="B",
            base_altitude_m=None,
            top_altitude_m=1240.0,
            source="openskidata",
        ),
    ]
    resorts = FakeResortRepository([resort])
    service = ResortMergeService(
        resort_repository=resorts,  # type: ignore[arg-type]
        record_repository=FakeRecordRepository([record]),  # type: ignore[arg-type]
        override_repository=FakeOverrideRepository([]),  # type: ignore[arg-type]
        lift_repository=FakeLiftRepository(lifts),  # type: ignore[arg-type]
        clock=lambda: NOW,
    )

    summary = service.merge_stale()

    assert summary.merged_count == 1 and summary.changed_count == 1
    assert resort.name == "Grouse Mountain" and resort.city == "North Vancouver"
    assert resort.country_code == "CA" and resort.region_code == "CA-BC"
    assert (resort.elevation_base_m, resort.elevation_top_m) == (880, 1250)
    assert resort.field_provenance["elevation_top_m"] == "openskidata"
    assert resort.last_merged_at == NOW
    assert resorts.committed == 0  # callers commit; the merge service never does

    changed_again = service.merge_resort(resort)
    assert changed_again is False


def test_service_deactivates_when_primary_record_is_missing() -> None:
    resort = Resort(
        id=uuid.uuid4(),
        name="Grouse Mountain",
        country="Canada",
        region="BC",
        is_active=True,
        name_aliases=[],
        field_provenance={},
    )
    record = ResortSourceRecord(
        source=SOURCE_OPENSKIDATA,
        external_id="osd-grouse",
        payload=_grouse_feature(),
        content_hash="h",
        fetched_at=NOW,
        missing_since=NOW,
        resort_id=resort.id,
        match_status="linked",
        match_method="primary",
    )
    service = ResortMergeService(
        resort_repository=FakeResortRepository([resort]),  # type: ignore[arg-type]
        record_repository=FakeRecordRepository([record]),  # type: ignore[arg-type]
        override_repository=FakeOverrideRepository([]),  # type: ignore[arg-type]
        lift_repository=FakeLiftRepository([]),  # type: ignore[arg-type]
        clock=lambda: NOW,
    )

    summary = service.merge_stale()

    assert resort.is_active is False and summary.deactivated_count == 1
