"""create ride sessions and session points tables

Revision ID: 0003_sessions_points
Revises: 0002_resorts_favorites
Create Date: 2026-03-17 10:05:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0003_sessions_points"
down_revision: Union[str, None] = "0002_resorts_favorites"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    ride_session_status = sa.Enum(
        "DRAFT",
        "COMPLETED",
        "SYNCED",
        name="ride_session_status",
    )

    op.create_table(
        "ride_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("resort_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column(
            "started_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("duration_s", sa.Integer(), nullable=True),
        sa.Column("distance_m", sa.Float(), nullable=True),
        sa.Column("max_speed_mps", sa.Float(), nullable=True),
        sa.Column("avg_speed_mps", sa.Float(), nullable=True),
        sa.Column("elevation_gain_m", sa.Integer(), nullable=True),
        sa.Column("elevation_loss_m", sa.Integer(), nullable=True),
        sa.Column(
            "status",
            ride_session_status,
            server_default=sa.text("'DRAFT'"),
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["resort_id"], ["resorts.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_ride_sessions_user_id"),
        "ride_sessions",
        ["user_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_ride_sessions_resort_id"),
        "ride_sessions",
        ["resort_id"],
        unique=False,
    )
    op.create_index(
        "ix_ride_sessions_user_id_started_at",
        "ride_sessions",
        ["user_id", "started_at"],
        unique=False,
    )

    op.create_table(
        "session_points",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("t_offset_ms", sa.Integer(), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("accuracy_m", sa.Float(), nullable=True),
        sa.Column("altitude_m", sa.Float(), nullable=True),
        sa.Column("speed_mps", sa.Float(), nullable=True),
        sa.Column("heading_deg", sa.Float(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["session_id"], ["ride_sessions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_session_points_session_id"),
        "session_points",
        ["session_id"],
        unique=False,
    )
    op.create_index(
        "ix_session_points_session_id_t_offset_ms",
        "session_points",
        ["session_id", "t_offset_ms"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_session_points_session_id_t_offset_ms",
        table_name="session_points",
    )
    op.drop_index(op.f("ix_session_points_session_id"), table_name="session_points")
    op.drop_table("session_points")

    op.drop_index(
        "ix_ride_sessions_user_id_started_at",
        table_name="ride_sessions",
    )
    op.drop_index(op.f("ix_ride_sessions_resort_id"), table_name="ride_sessions")
    op.drop_index(op.f("ix_ride_sessions_user_id"), table_name="ride_sessions")
    op.drop_table("ride_sessions")

    ride_session_status = sa.Enum(
        "DRAFT",
        "COMPLETED",
        "SYNCED",
        name="ride_session_status",
    )
    ride_session_status.drop(op.get_bind(), checkfirst=True)
