from datetime import datetime
from uuid import UUID

from app.schemas.base import ORMBaseModel


class UserPublic(ORMBaseModel):
    id: UUID
    email: str
    display_name: str
    created_at: datetime
