"""add resort source metadata

Revision ID: 0007_resort_source_metadata
Revises: 0006_session_point_enriched
Create Date: 2026-03-18 20:10:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "0007_resort_source_metadata"
down_revision: Union[str, None] = "0006_session_point_enriched"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "resorts",
        sa.Column("external_source", sa.String(length=50), nullable=True),
    )
    op.add_column(
        "resorts",
        sa.Column("external_id", sa.String(length=160), nullable=True),
    )
    op.add_column(
        "resorts",
        sa.Column("last_source_sync_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "resorts",
        sa.Column(
            "is_active",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("true"),
        ),
    )
    op.create_index(op.f("ix_resorts_is_active"), "resorts", ["is_active"], unique=False)
    op.create_unique_constraint(
        "uq_resorts_external_source_external_id",
        "resorts",
        ["external_source", "external_id"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_resorts_external_source_external_id",
        "resorts",
        type_="unique",
    )
    op.drop_index(op.f("ix_resorts_is_active"), table_name="resorts")
    op.drop_column("resorts", "is_active")
    op.drop_column("resorts", "last_source_sync_at")
    op.drop_column("resorts", "external_id")
    op.drop_column("resorts", "external_source")
