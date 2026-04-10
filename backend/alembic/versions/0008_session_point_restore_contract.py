"""add canonical restore-contract fields to session points

Revision ID: 0008_point_restore_contract
Revises: 0007_resort_source_metadata
Create Date: 2026-04-08 00:00:00
"""

from typing import Any
from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "0008_point_restore_contract"
down_revision: Union[str, None] = "0007_resort_source_metadata"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _existing_session_point_columns() -> dict[str, dict[str, Any]]:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if not inspector.has_table("session_points"):
        return {}
    return {column["name"]: column for column in inspector.get_columns("session_points")}


def upgrade() -> None:
    existing_columns = _existing_session_point_columns()
    if not existing_columns:
        return

    if "recorded_at" not in existing_columns:
        op.add_column(
            "session_points",
            sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=True),
        )

    op.execute(
        """
        UPDATE session_points AS sp
        SET recorded_at = rs.started_at + (sp.t_offset_ms * INTERVAL '1 millisecond')
        FROM ride_sessions AS rs
        WHERE rs.id = sp.session_id
        AND sp.recorded_at IS NULL
        """
    )

    if _existing_session_point_columns().get("recorded_at", {}).get("nullable", True):
        op.alter_column("session_points", "recorded_at", nullable=False)

    if "accepted_for_analytics" not in existing_columns:
        op.add_column(
            "session_points",
            sa.Column(
                "accepted_for_analytics",
                sa.Boolean(),
                nullable=True,
                server_default=sa.text("true"),
            ),
        )

    op.execute(
        """
        UPDATE session_points
        SET accepted_for_analytics = true
        WHERE accepted_for_analytics IS NULL
        """
    )
    op.alter_column(
        "session_points",
        "accepted_for_analytics",
        nullable=False,
        server_default=sa.text("true"),
    )


def downgrade() -> None:
    existing_columns = _existing_session_point_columns()
    if "accepted_for_analytics" in existing_columns:
        op.drop_column("session_points", "accepted_for_analytics")
    if "recorded_at" in existing_columns:
        op.drop_column("session_points", "recorded_at")
