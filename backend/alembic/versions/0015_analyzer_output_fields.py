"""analyzer output fields

Revision ID: 0015_analyzer_output_fields
Revises: 0014_session_point_pressure
Create Date: 2026-09-17 12:10:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

revision: str = "0015_analyzer_output_fields"
down_revision: Union[str, None] = "0014_session_point_pressure"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("resort_lifts", sa.Column("osm_aerialway", sa.Text(), nullable=True))
    op.add_column("ride_session_actions", sa.Column("lift_name", sa.Text(), nullable=True))
    op.add_column(
        "ride_sessions",
        sa.Column("break_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
    )
    op.add_column(
        "ride_sessions",
        sa.Column("break_duration_s", sa.Numeric(10, 3), nullable=False, server_default=sa.text("0")),
    )


def downgrade() -> None:
    op.drop_column("ride_sessions", "break_duration_s")
    op.drop_column("ride_sessions", "break_count")
    op.drop_column("ride_session_actions", "lift_name")
    op.drop_column("resort_lifts", "osm_aerialway")
