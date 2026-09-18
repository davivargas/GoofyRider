"""session point pressure

Revision ID: 0014_session_point_pressure
Revises: 0013_refresh_tokens
Create Date: 2026-09-17 12:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

revision: str = "0014_session_point_pressure"
down_revision: Union[str, None] = "0013_refresh_tokens"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("session_points", sa.Column("pressure_hpa", sa.Numeric(7, 2), nullable=True))


def downgrade() -> None:
    op.drop_column("session_points", "pressure_hpa")
