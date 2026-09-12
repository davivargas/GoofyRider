from datetime import datetime
from datetime import timedelta
import uuid

from sqlalchemy import delete
from sqlalchemy import or_
from sqlalchemy import select
from sqlalchemy import update

from app.models.refresh_token import RefreshToken
from app.repositories.base import SqlAlchemyRepository

ROTATED_TOKEN_RETENTION = timedelta(days=7)


class RefreshTokenRepository(SqlAlchemyRepository):
    def add(self, token: RefreshToken) -> None:
        self._db.add(token)

    def get_by_hash(self, token_hash: str) -> RefreshToken | None:
        return self._db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))

    def revoke(
        self,
        token: RefreshToken,
        *,
        now: datetime,
        replaced_by: RefreshToken | None = None,
    ) -> None:
        token.revoked_at = now
        if replaced_by is not None:
            self._db.add(replaced_by)
            self._db.flush()
            token.replaced_by_id = replaced_by.id

    def revoke_family(self, family_id: uuid.UUID, *, now: datetime) -> int:
        result = self._db.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=now)
        )
        return int(getattr(result, "rowcount", 0) or 0)

    def delete_expired(self, *, now: datetime) -> int:
        result = self._db.execute(
            delete(RefreshToken).where(
                or_(
                    RefreshToken.family_expires_at < now,
                    RefreshToken.expires_at < now - ROTATED_TOKEN_RETENTION,
                )
            )
        )
        return int(getattr(result, "rowcount", 0) or 0)
