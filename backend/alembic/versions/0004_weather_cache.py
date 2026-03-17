"""add weather cache table and dedupe session point offsets

Revision ID: 0004_weather_cache
Revises: 0003_sessions_points
Create Date: 2026-03-17 11:40:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0004_weather_cache"
down_revision: Union[str, None] = "0003_sessions_points"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "weather_cache",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("resort_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("temp_c", sa.Float(), nullable=True),
        sa.Column("wind_kph", sa.Float(), nullable=True),
        sa.Column("snowfall_cm_24h", sa.Float(), nullable=True),
        sa.Column("conditions_text", sa.String(length=120), nullable=True),
        sa.Column("today_high_c", sa.Float(), nullable=True),
        sa.Column("today_low_c", sa.Float(), nullable=True),
        sa.Column("snowfall_next_24h_cm", sa.Float(), nullable=True),
        sa.Column("weather_code_text", sa.String(length=120), nullable=True),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.ForeignKeyConstraint(["resort_id"], ["resorts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("resort_id", name="uq_weather_cache_resort_id"),
    )
    op.create_index(op.f("ix_weather_cache_resort_id"), "weather_cache", ["resort_id"], unique=False)

    op.create_unique_constraint(
        "uq_session_points_session_id_t_offset_ms",
        "session_points",
        ["session_id", "t_offset_ms"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_session_points_session_id_t_offset_ms",
        "session_points",
        type_="unique",
    )

    op.drop_index(op.f("ix_weather_cache_resort_id"), table_name="weather_cache")
    op.drop_table("weather_cache")
