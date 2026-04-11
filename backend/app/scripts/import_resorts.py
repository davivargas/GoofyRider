from app.core.config import get_ski_api_base_url
from app.core.config import get_ski_api_host
from app.core.config import get_ski_api_key
from app.core.config import get_ski_api_page_size
from app.core.config import get_ski_api_timeout_seconds
from app.core.database import get_session_local
from app.repositories.resort_repository import ResortRepository
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.resort_import_service import ResortImportService
from app.services.ski_api_resort_source import SkiApiResortSource


def import_resorts() -> tuple[int, int, int]:
    db = get_session_local()()
    try:
        resort_repository = ResortRepository(db)
        resort_source = SkiApiResortSource(
            base_url=get_ski_api_base_url(),
            api_key=get_ski_api_key(),
            api_host=get_ski_api_host(),
            page_size=get_ski_api_page_size(),
            timeout_seconds=get_ski_api_timeout_seconds(),
        )
        import_service = ResortImportService(
            resort_repository=resort_repository,
            resort_source=resort_source,
            deactivate_missing=False,
        )
        summary = import_service.import_resorts()
    finally:
        db.close()

    return (
        summary.created_count,
        summary.updated_count,
        summary.deactivated_count,
    )


def main() -> None:
    try:
        created_count, updated_count, deactivated_count = import_resorts()
    except (ServiceUnavailableError, ValidationError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc

    print(
        "Import complete. "
        f"Created: {created_count}, "
        f"Updated: {updated_count}, "
        f"Deactivated: {deactivated_count}"
    )


if __name__ == "__main__":
    main()
