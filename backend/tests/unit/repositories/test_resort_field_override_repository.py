from collections.abc import Callable

from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.repositories.resort_field_override_repository import ResortFieldOverrideRepository


def test_upsert_replaces_value_for_same_field(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortFieldOverrideRepository(db)
    repo.upsert(resort.id, "city", "Whistler", note="fixed")
    repo.upsert(resort.id, "city", "Whistler Village", note=None)
    repo.upsert(resort.id, "elevation_top_m", 2284, note=None)
    repo.commit()

    overrides = {o.field: o.value for o in repo.list_by_resort(resort.id)}
    assert overrides == {"city": "Whistler Village", "elevation_top_m": 2284}


def test_delete_returns_count(db: Session, create_resort: Callable[..., Resort]) -> None:
    resort = create_resort()
    repo = ResortFieldOverrideRepository(db)
    repo.upsert(resort.id, "is_active", False, note=None)
    repo.commit()

    assert repo.delete(resort.id, "is_active") == 1
    assert repo.delete(resort.id, "is_active") == 0
