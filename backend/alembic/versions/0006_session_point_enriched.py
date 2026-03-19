"""add enriched tracking fields to session points

Revision ID: 0006_session_point_enriched
Revises: 0004_weather_cache
Create Date: 2026-03-18 00:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "0006_session_point_enriched"
down_revision: Union[str, None] = "0004_weather_cache"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _session_point_enriched_columns() -> list[sa.Column]:
    return [
        sa.Column("elapsed_realtime_ns", sa.BigInteger(), nullable=True),
        sa.Column("vertical_accuracy_m", sa.Float(), nullable=True),
        sa.Column("speed_accuracy_mps", sa.Float(), nullable=True),
        sa.Column("bearing_accuracy_deg", sa.Float(), nullable=True),
        sa.Column("provider", sa.Text(), nullable=True),
        sa.Column("is_mocked", sa.Boolean(), nullable=True),
        sa.Column("quality_class", sa.Text(), nullable=True),
        sa.Column("quality_score", sa.Float(), nullable=True),
        sa.Column("quality_reason", sa.Text(), nullable=True),
        sa.Column("filtered_latitude", sa.Float(), nullable=True),
        sa.Column("filtered_longitude", sa.Float(), nullable=True),
        sa.Column("filtered_altitude_m", sa.Float(), nullable=True),
        sa.Column("fused_speed_mps", sa.Float(), nullable=True),
        sa.Column("derived_speed_mps", sa.Float(), nullable=True),
        sa.Column("distance_delta_m", sa.Float(), nullable=True),
        sa.Column("motion_state", sa.Text(), nullable=True),
    ]


def _existing_session_point_columns() -> set[str]:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if not inspector.has_table("session_points"):
        return set()
    return {column["name"] for column in inspector.get_columns("session_points")}


def upgrade() -> None:
    existing_columns = _existing_session_point_columns()
    for column in _session_point_enriched_columns():
        if column.name not in existing_columns:
            op.add_column("session_points", column)


def downgrade() -> None:
    existing_columns = _existing_session_point_columns()
    for column in reversed(_session_point_enriched_columns()):
        if column.name in existing_columns:
            op.drop_column("session_points", column.name)
