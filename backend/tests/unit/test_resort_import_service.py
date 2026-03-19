from datetime import UTC
from datetime import datetime

from app.models.resort import Resort
from app.services.resort_import_service import ResortImportService
from app.services.ski_api_resort_source import ExternalResortRecord

IMPORTED_AT = datetime(2026, 3, 18, 20, 30, tzinfo=UTC)


class FakeResortRepository:
    def __init__(self, resorts: list[Resort] | None = None) -> None:
        self.resorts = resorts or []
        self.committed = False

    def add(self, resort: Resort) -> None:
        self.resorts.append(resort)

    def commit(self) -> None:
        self.committed = True

    def get_by_external_ref(self, external_source: str, external_id: str) -> Resort | None:
        for resort in self.resorts:
            if resort.external_source == external_source and resort.external_id == external_id:
                return resort
        return None

    def get_by_name_country_region(
        self,
        name: str,
        country: str,
        region: str,
    ) -> Resort | None:
        for resort in self.resorts:
            if resort.name == name and resort.country == country and resort.region == region:
                return resort
        return None

    def list_by_external_source(self, external_source: str) -> list[Resort]:
        return [resort for resort in self.resorts if resort.external_source == external_source]

    def list_by_name(self, name: str) -> list[Resort]:
        return [resort for resort in self.resorts if resort.name == name]


class FakeResortSource:
    def __init__(self, resorts: list[ExternalResortRecord]) -> None:
        self._resorts = resorts

    def fetch_resorts(self) -> list[ExternalResortRecord]:
        return list(self._resorts)


def test_import_resorts_creates_new_records() -> None:
    repository = FakeResortRepository()
    service = ResortImportService(
        resort_repository=repository,
        resort_source=FakeResortSource([_build_external_resort()]),
        clock=lambda: IMPORTED_AT,
    )

    summary = service.import_resorts()

    assert summary.created_count == 1
    assert summary.updated_count == 0
    assert summary.deactivated_count == 0
    assert repository.committed is True
    assert repository.resorts[0].external_id == "whistler-blackcomb"
    assert repository.resorts[0].last_source_sync_at == IMPORTED_AT


def test_import_resorts_updates_existing_seeded_resort_by_identity() -> None:
    existing = Resort(
        name="Whistler Blackcomb",
        country="Canada",
        region="British Columbia",
        city="Whistler",
        latitude=50.1,
        longitude=-122.9,
        elevation_base_m=675,
        elevation_top_m=2284,
        is_active=True,
    )
    repository = FakeResortRepository(resorts=[existing])
    service = ResortImportService(
        resort_repository=repository,
        resort_source=FakeResortSource([_build_external_resort(city=None)]),
        clock=lambda: IMPORTED_AT,
    )

    summary = service.import_resorts()

    assert summary.created_count == 0
    assert summary.updated_count == 1
    assert existing.external_source == "ski_api"
    assert existing.external_id == "whistler-blackcomb"
    assert existing.last_source_sync_at == IMPORTED_AT
    assert existing.city == "Whistler"


def test_import_resorts_does_not_deactivate_missing_resorts_by_default() -> None:
    existing = Resort(
        name="Legacy Resort",
        country="Canada",
        region="British Columbia",
        city=None,
        latitude=None,
        longitude=None,
        elevation_base_m=None,
        elevation_top_m=None,
        external_source="ski_api",
        external_id="legacy-resort",
        is_active=True,
    )
    repository = FakeResortRepository(resorts=[existing])
    service = ResortImportService(
        resort_repository=repository,
        resort_source=FakeResortSource([_build_external_resort()]),
        clock=lambda: IMPORTED_AT,
    )

    summary = service.import_resorts()

    assert summary.deactivated_count == 0
    assert existing.is_active is True


def test_import_resorts_can_deactivate_missing_imported_resorts() -> None:
    existing = Resort(
        name="Legacy Resort",
        country="Canada",
        region="British Columbia",
        city=None,
        latitude=None,
        longitude=None,
        elevation_base_m=None,
        elevation_top_m=None,
        external_source="ski_api",
        external_id="legacy-resort",
        is_active=True,
    )
    repository = FakeResortRepository(resorts=[existing])
    service = ResortImportService(
        resort_repository=repository,
        resort_source=FakeResortSource([_build_external_resort()]),
        deactivate_missing=True,
        clock=lambda: IMPORTED_AT,
    )

    summary = service.import_resorts()

    assert summary.deactivated_count == 1
    assert existing.is_active is False


def _build_external_resort(city: str | None = "Whistler") -> ExternalResortRecord:
    return ExternalResortRecord(
        external_source="ski_api",
        external_id="whistler-blackcomb",
        name="Whistler Blackcomb",
        country="Canada",
        region="British Columbia",
        city=city,
        latitude=50.10693,
        longitude=-122.922073,
        elevation_base_m=None,
        elevation_top_m=None,
    )
