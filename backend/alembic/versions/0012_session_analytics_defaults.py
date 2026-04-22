"""session analytics defaults

Revision ID: 0012_session_analytics_defaults
Revises: 0011_session_analyzer_schema
Create Date: 2026-04-21 12:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '0012_session_analytics_defaults'
down_revision: Union[str, None] = '0011_session_analyzer_schema'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_ANALYTICS_COLUMNS: tuple[str, ...] = (
    'total_duration_s',
    'descent_duration_s',
    'lift_duration_s',
    'descent_distance_m',
    'lift_distance_m',
    'descent_vertical_m',
    'lift_vertical_m',
    'avg_descent_speed_mps',
)


def upgrade() -> None:
    for column in _ANALYTICS_COLUMNS:
        op.alter_column(
            'ride_sessions',
            column,
            server_default=sa.text('0'),
        )


def downgrade() -> None:
    for column in _ANALYTICS_COLUMNS:
        op.alter_column(
            'ride_sessions',
            column,
            server_default=None,
        )
