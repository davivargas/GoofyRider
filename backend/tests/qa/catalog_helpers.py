from pathlib import Path

from sqlalchemy.orm import Session

from app.repositories.resort_field_override_repository import ResortFieldOverrideRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.resort_source_record_repository import ResortSourceRecordRepository
from app.services.openskidata_source import OpenSkiDataSource
from app.services.resort_catalog_import_service import CatalogImportOptions
from app.services.resort_catalog_import_service import CatalogImportSummary
from app.services.resort_catalog_import_service import ResortCatalogImportService
from app.services.resort_lift_sync_service import ResortLiftSyncService
from app.services.resort_merge_service import ResortMergeService
from app.services.resort_source_record_service import ResortSourceRecordService

OPENSKIDATA_FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "openskidata"


def run_fixture_import(db: Session) -> CatalogImportSummary:
    resorts = ResortRepository(db)
    records = ResortSourceRecordRepository(db)
    overrides = ResortFieldOverrideRepository(db)
    lifts = ResortLiftRepository(db)
    importer = ResortCatalogImportService(
        resort_repository=resorts,
        record_repository=records,
        override_repository=overrides,
        lift_repository=lifts,
        record_service=ResortSourceRecordService(records),
        merge_service=ResortMergeService(resorts, records, overrides, lifts),
        lift_sync_service=ResortLiftSyncService(records, lifts),
    )
    with OpenSkiDataSource(
        base_url="https://unused.test", timeout_seconds=1, local_dir=OPENSKIDATA_FIXTURES
    ) as source:
        return importer.import_openskidata(source, CatalogImportOptions())
