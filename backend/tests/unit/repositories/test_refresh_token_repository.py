from collections.abc import Callable
from datetime import UTC
from datetime import datetime
from datetime import timedelta
from uuid import uuid4

from sqlalchemy.orm import Session

from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.repositories.refresh_token_repository import RefreshTokenRepository


def _token(user: User, *, family_id=None, hash_suffix: str = "a") -> RefreshToken:
    now = datetime.now(UTC)
    return RefreshToken(
        user_id=user.id,
        token_hash=(hash_suffix * 64)[:64],
        family_id=family_id or uuid4(),
        issued_at=now,
        expires_at=now + timedelta(days=30),
        family_expires_at=now + timedelta(days=90),
    )


def test_add_and_get_by_hash(db: Session, create_user: Callable[..., User]) -> None:
    repo = RefreshTokenRepository(db)
    token = _token(create_user())

    repo.add(token)
    repo.commit()

    assert repo.get_by_hash(token.token_hash) is not None
    assert repo.get_by_hash("b" * 64) is None


def test_revoke_links_successor(db: Session, create_user: Callable[..., User]) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    old = _token(user, hash_suffix="1")
    repo.add(old)
    repo.commit()
    successor = _token(user, family_id=old.family_id, hash_suffix="2")
    now = datetime.now(UTC)

    repo.revoke(old, now=now, replaced_by=successor)
    repo.commit()

    stored_old = repo.get_by_hash(old.token_hash)
    stored_new = repo.get_by_hash(successor.token_hash)
    assert stored_old is not None and stored_new is not None
    assert stored_old.revoked_at is not None
    assert stored_old.replaced_by_id == stored_new.id
    assert stored_new.revoked_at is None


def test_revoke_family_only_touches_active_members(
    db: Session, create_user: Callable[..., User]
) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    family = uuid4()
    first = _token(user, family_id=family, hash_suffix="3")
    second = _token(user, family_id=family, hash_suffix="4")
    other = _token(user, hash_suffix="5")
    for token in (first, second, other):
        repo.add(token)
    repo.commit()
    repo.revoke(first, now=datetime.now(UTC))
    repo.commit()

    count = repo.revoke_family(family, now=datetime.now(UTC))
    repo.commit()

    assert count == 1
    assert repo.get_by_hash(second.token_hash).revoked_at is not None
    assert repo.get_by_hash(other.token_hash).revoked_at is None


def test_delete_expired_removes_dead_families_and_old_rotations(
    db: Session, create_user: Callable[..., User]
) -> None:
    repo = RefreshTokenRepository(db)
    user = create_user()
    now = datetime.now(UTC)
    dead_family = _token(user, hash_suffix="6")
    dead_family.family_expires_at = now - timedelta(days=1)
    old_rotation = _token(user, hash_suffix="7")
    old_rotation.expires_at = now - timedelta(days=8)
    alive = _token(user, hash_suffix="8")
    for token in (dead_family, old_rotation, alive):
        repo.add(token)
    repo.commit()

    removed = repo.delete_expired(now=now)
    repo.commit()

    assert removed == 2
    assert repo.get_by_hash(alive.token_hash) is not None
