"""split session_point analytics into dedicated table

Revision ID: 0010_session_point_analytics
Revises: 0009_session_point_enums
Create Date: 2026-04-13 00:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0010_session_point_analytics"
down_revision: Union[str, None] = "0009_session_point_enums"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    quality_class_enum = postgresql.ENUM(
        "accept",
        "accept_low_confidence",
        "reject",
        name="quality_class",
        create_type=False,
    )
    motion_state_enum = postgresql.ENUM(
        "initializing_fix",
        "active_descent",
        "lift_uphill",
        "stopped_idle",
        "low_confidence_recovery",
        name="motion_state",
        create_type=False,
    )

    op.create_table(
        "session_point_analytics",
        sa.Column("session_point_id", sa.BigInteger(), nullable=False),
        sa.Column("quality_class", quality_class_enum, nullable=True),
        sa.Column("quality_score", sa.Float(), nullable=True),
        sa.Column("quality_reason", sa.Text(), nullable=True),
        sa.Column("filtered_latitude", sa.Float(), nullable=True),
        sa.Column("filtered_longitude", sa.Float(), nullable=True),
        sa.Column("filtered_altitude_m", sa.Float(), nullable=True),
        sa.Column("fused_speed_mps", sa.Float(), nullable=True),
        sa.Column("derived_speed_mps", sa.Float(), nullable=True),
        sa.Column("distance_delta_m", sa.Float(), nullable=True),
        sa.Column("motion_state", motion_state_enum, nullable=True),
        sa.Column(
            "accepted_for_analytics",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
        sa.ForeignKeyConstraint(
            ["session_point_id"],
            ["session_points.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("session_point_id"),
    )

    op.execute(
        """
        INSERT INTO session_point_analytics (
            session_point_id,
            quality_class,
            quality_score,
            quality_reason,
            filtered_latitude,
            filtered_longitude,
            filtered_altitude_m,
            fused_speed_mps,
            derived_speed_mps,
            distance_delta_m,
            motion_state,
            accepted_for_analytics
        )
        SELECT
            id,
            quality_class,
            quality_score,
            quality_reason,
            filtered_latitude,
            filtered_longitude,
            filtered_altitude_m,
            fused_speed_mps,
            derived_speed_mps,
            distance_delta_m,
            motion_state,
            COALESCE(accepted_for_analytics, true)
        FROM session_points
        ON CONFLICT (session_point_id) DO NOTHING
        """
    )


def downgrade() -> None:
    op.drop_table("session_point_analytics")
