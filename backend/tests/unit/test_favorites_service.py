from uuid import uuid4

import pytest

from app.models.resort import Resort
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.favorites_service import FavoritesService


class FakeResortRepository:
    def __init__(self) -> None:
        self.resorts: dict[object, Resort] = {}

    def get_by_id(self, resort_id):
        return self.resorts.get(resort_id)


class FakeFavoriteResortRepository:
    def __init__(self) -> None:
        self.entries: set[tuple[object, object]] = set()
        self.did_commit = False

    def list_by_user_id(self, user_id):
        return []

    def exists(self, user_id, resort_id):
        return (user_id, resort_id) in self.entries

    def add(self, user_id, resort_id):
        self.entries.add((user_id, resort_id))

    def delete(self, user_id, resort_id):
        self.entries.discard((user_id, resort_id))
        return 1

    def commit(self):
        self.did_commit = True

    def rollback(self):
        return None


def _build_resort() -> Resort:
    resort = Resort(
        name="Whistler Blackcomb",
        country="Canada",
        region="British Columbia",
        city="Whistler",
    )
    resort.id = uuid4()
    return resort


def test_add_favorite_rejects_unknown_resort() -> None:
    service = FavoritesService(
        resort_repository=FakeResortRepository(),
        favorite_resort_repository=FakeFavoriteResortRepository(),
    )

    with pytest.raises(NotFoundError, match="Resort not found."):
        service.add_favorite(user_id=uuid4(), resort_id=uuid4())


def test_add_favorite_rejects_duplicate() -> None:
    user_id = uuid4()
    resort = _build_resort()
    resort_repository = FakeResortRepository()
    resort_repository.resorts[resort.id] = resort
    favorites_repository = FakeFavoriteResortRepository()
    favorites_repository.entries.add((user_id, resort.id))
    service = FavoritesService(
        resort_repository=resort_repository,
        favorite_resort_repository=favorites_repository,
    )

    with pytest.raises(ConflictError, match="Resort is already in favorites."):
        service.add_favorite(user_id=user_id, resort_id=resort.id)


def test_remove_favorite_rejects_missing_favorite() -> None:
    service = FavoritesService(
        resort_repository=FakeResortRepository(),
        favorite_resort_repository=FakeFavoriteResortRepository(),
    )

    with pytest.raises(NotFoundError, match="Favorite resort not found."):
        service.remove_favorite(user_id=uuid4(), resort_id=uuid4())
