from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class UserPublic(BaseModel):
    id: UUID
    email: str
    display_name: str
    created_at: datetime

    model_config = {"from_attributes": True}
