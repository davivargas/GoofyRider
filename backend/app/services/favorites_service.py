import uuid
from typing import Protocol

from sqlalchemy.exc import IntegrityError

from app.models.resort import Resort
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError


class ResortRepositoryProtocol(Protocol):
    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None:
        ...


class FavoriteResortRepositoryProtocol(Protocol):
    def list_by_user_id(self, user_id: uuid.UUID) -> list[Resort]:
        ...

    def exists(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> bool:
        ...

    def add(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> None:
        ...

    def delete(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> int:
        ...

    def commit(self) -> None:
        ...

    def rollback(self) -> None:
        ...


class FavoritesService:
    def __init__(
        self,
        resort_repository: ResortRepositoryProtocol,
        favorite_resort_repository: FavoriteResortRepositoryProtocol,
    ) -> None:
        self._resort_repository = resort_repository
        self._favorite_resort_repository = favorite_resort_repository

    def list_favorites(self, user_id: uuid.UUID) -> list[Resort]:
        return self._favorite_resort_repository.list_by_user_id(user_id)

    def add_favorite(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> Resort:
        resort = self._resort_repository.get_by_id(resort_id)
        if resort is None:
            raise NotFoundError("Resort not found.")

        already_favorite = self._favorite_resort_repository.exists(user_id, resort_id)
        if already_favorite:
            raise ConflictError("Resort is already in favorites.")

        self._favorite_resort_repository.add(user_id, resort_id)
        try:
            self._favorite_resort_repository.commit()
        except IntegrityError as exc:
            self._favorite_resort_repository.rollback()
            raise ConflictError("Resort is already in favorites.") from exc

        return resort

    def remove_favorite(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> None:
        favorite_exists = self._favorite_resort_repository.exists(user_id, resort_id)
        if not favorite_exists:
            raise NotFoundError("Favorite resort not found.")

        self._favorite_resort_repository.delete(user_id, resort_id)
        self._favorite_resort_repository.commit()
