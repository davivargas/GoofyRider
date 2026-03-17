"""create resorts and favorite resorts tables

Revision ID: 0002_resorts_favorites
Revises: 0001_create_users_table
Create Date: 2026-03-16 18:05:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0002_resorts_favorites"
down_revision: Union[str, None] = "0001_create_users_table"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "resorts",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("country", sa.String(length=100), nullable=False),
        sa.Column("region", sa.String(length=100), nullable=False),
        sa.Column("city", sa.String(length=100), nullable=True),
        sa.Column("latitude", sa.Float(), nullable=True),
        sa.Column("longitude", sa.Float(), nullable=True),
        sa.Column("elevation_base_m", sa.Integer(), nullable=True),
        sa.Column("elevation_top_m", sa.Integer(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "name",
            "country",
            "region",
            name="uq_resorts_name_country_region",
        ),
    )
    op.create_index(op.f("ix_resorts_name"), "resorts", ["name"], unique=False)
    op.create_index(op.f("ix_resorts_region"), "resorts", ["region"], unique=False)

    op.create_table(
        "favorite_resorts",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("resort_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["resort_id"], ["resorts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "resort_id"),
    )
    op.create_index(
        "ix_favorite_resorts_resort_id",
        "favorite_resorts",
        ["resort_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_favorite_resorts_resort_id", table_name="favorite_resorts")
    op.drop_table("favorite_resorts")
    op.drop_index(op.f("ix_resorts_region"), table_name="resorts")
    op.drop_index(op.f("ix_resorts_name"), table_name="resorts")
    op.drop_table("resorts")
