"""convert session_points provider/motion_state/quality_class to Postgres enums

Revision ID: 0009_session_point_enums
Revises: 0008_point_restore_contract
Create Date: 2026-04-13 00:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0009_session_point_enums"
down_revision: Union[str, None] = "0008_point_restore_contract"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


PROVIDER_VALUES = ("gps", "fused", "network", "passive", "unknown")
MOTION_STATE_VALUES = (
    "initializing_fix",
    "active_descent",
    "lift_uphill",
    "stopped_idle",
    "low_confidence_recovery",
)
QUALITY_CLASS_VALUES = ("accept", "accept_low_confidence", "reject")


def _create_enum(name: str, values: tuple[str, ...]) -> None:
    quoted = ", ".join(f"'{value}'" for value in values)
    op.execute(f"CREATE TYPE {name} AS ENUM ({quoted})")


def _alter_column_to_enum(column: str, enum_name: str) -> None:
    op.execute(
        f"ALTER TABLE session_points "
        f"ALTER COLUMN {column} TYPE {enum_name} USING {column}::{enum_name}"
    )


def _alter_column_to_text(column: str) -> None:
    op.execute(f"ALTER TABLE session_points ALTER COLUMN {column} TYPE text USING {column}::text")


def upgrade() -> None:
    _create_enum("provider_type", PROVIDER_VALUES)
    _create_enum("motion_state", MOTION_STATE_VALUES)
    _create_enum("quality_class", QUALITY_CLASS_VALUES)

    _alter_column_to_enum("provider", "provider_type")
    _alter_column_to_enum("motion_state", "motion_state")
    _alter_column_to_enum("quality_class", "quality_class")


def downgrade() -> None:
    _alter_column_to_text("provider")
    _alter_column_to_text("motion_state")
    _alter_column_to_text("quality_class")

    op.execute("DROP TYPE IF EXISTS quality_class")
    op.execute("DROP TYPE IF EXISTS motion_state")
    op.execute("DROP TYPE IF EXISTS provider_type")
