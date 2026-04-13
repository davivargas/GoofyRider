"""Consolidated repository protocol definitions.

Each service imports the protocol it needs from this module instead of
defining its own inline Protocol class.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Protocol
import uuid

from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.session_point import SessionPoint
from app.models.user import User
from app.models.weather_cache import WeatherCache


class UserRepositoryProtocol(Protocol):
    def get_by_email(self, email: str) -> User | None: ...

    def get_by_id(self, user_id: uuid.UUID) -> User | None: ...

    def add(self, user: User) -> None: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...

    def refresh(self, instance: object) -> None: ...


class ResortRepositoryProtocol(Protocol):
    """Union of all resort-related repository methods used across services."""

    # Lookup (used by session, favorites, weather, and resort services)
    def get_by_id(self, resort_id: uuid.UUID) -> Resort | None: ...

    # Catalog (used by resort service)
    def count_filtered(self, query: str | None, region: str | None) -> int: ...

    def list_filtered(
        self,
        query: str | None,
        region: str | None,
        page: int,
        page_size: int,
    ) -> list[Resort]: ...

    def list_filtered_with_count(
        self,
        query: str | None,
        region: str | None,
        page: int,
        page_size: int,
    ) -> tuple[list[Resort], int]: ...

    # Import (used by resort import service)
    def add(self, resort: Resort) -> None: ...

    def commit(self) -> None: ...

    def get_by_external_ref(self, external_source: str, external_id: str) -> Resort | None: ...

    def get_by_name_country_region(
        self,
        name: str,
        country: str,
        region: str,
    ) -> Resort | None: ...

    def list_by_external_source(self, external_source: str) -> list[Resort]: ...


class RideSessionRepositoryProtocol(Protocol):
    def add(self, ride_session: RideSession) -> None: ...

    def delete(self, ride_session: RideSession) -> None: ...

    def get_owned_by_user(
        self, session_id: uuid.UUID, user_id: uuid.UUID
    ) -> RideSession | None: ...

    def count_by_user(self, user_id: uuid.UUID) -> int: ...

    def list_by_user(self, user_id: uuid.UUID, page: int, page_size: int) -> list[RideSession]: ...

    def list_by_user_with_count(
        self, user_id: uuid.UUID, page: int, page_size: int
    ) -> tuple[list[RideSession], int]: ...

    def commit(self) -> None: ...

    def refresh(self, instance: object) -> None: ...


class SessionPointRepositoryProtocol(Protocol):
    def add_batch(self, points: Sequence[SessionPoint]) -> None: ...

    def existing_elapsed_offsets_ms(
        self,
        session_id: uuid.UUID,
        elapsed_offsets_ms: Sequence[int],
    ) -> set[int]: ...

    def list_by_session(self, session_id: uuid.UUID) -> list[SessionPoint]: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...


class FavoriteResortRepositoryProtocol(Protocol):
    def list_by_user_id(self, user_id: uuid.UUID) -> list[Resort]: ...

    def exists(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> bool: ...

    def add(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> None: ...

    def delete(self, user_id: uuid.UUID, resort_id: uuid.UUID) -> int: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...


class WeatherCacheRepositoryProtocol(Protocol):
    def get_by_resort_id(self, resort_id: uuid.UUID) -> WeatherCache | None: ...

    def add(self, cache: WeatherCache) -> None: ...

    def commit(self) -> None: ...

    def rollback(self) -> None: ...

    def refresh(self, instance: object) -> None: ...


__all__ = [
    "FavoriteResortRepositoryProtocol",
    "ResortRepositoryProtocol",
    "RideSessionRepositoryProtocol",
    "SessionPointRepositoryProtocol",
    "UserRepositoryProtocol",
    "WeatherCacheRepositoryProtocol",
]
