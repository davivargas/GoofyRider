"""session analyzer schema

Revision ID: 0011_session_analyzer_schema
Revises: 0010_session_point_analytics
Create Date: 2026-04-16 14:30:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '0011_session_analyzer_schema'
down_revision: Union[str, None] = '0010_session_point_analytics'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_session_conditions_enum = postgresql.ENUM(
    'PACKED',
    'WET',
    'GRANULAR',
    'GROOMED',
    'POWDER',
    name='session_conditions',
)
_session_conditions_enum_existing = postgresql.ENUM(
    'PACKED',
    'WET',
    'GRANULAR',
    'GROOMED',
    'POWDER',
    name='session_conditions',
    create_type=False,
)
_motion_state_enum = sa.Enum(
    'initializing_fix',
    'active_descent',
    'lift_uphill',
    'stopped_idle',
    'low_confidence_recovery',
    name='motion_state',
)
_motion_state_enum_existing = postgresql.ENUM(
    'initializing_fix',
    'active_descent',
    'lift_uphill',
    'stopped_idle',
    'low_confidence_recovery',
    name='motion_state',
    create_type=False,
)
_quality_class_enum = sa.Enum(
    'accept',
    'accept_low_confidence',
    'reject',
    name='quality_class',
)
_quality_class_enum_existing = postgresql.ENUM(
    'accept',
    'accept_low_confidence',
    'reject',
    name='quality_class',
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    _session_conditions_enum.create(bind, checkfirst=True)

    op.create_table(
        'ride_session_actions',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('session_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('action_type', sa.Text(), nullable=False),
        sa.Column('sequence_index', sa.Integer(), nullable=False),
        sa.Column('started_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('ended_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('duration_s', sa.Numeric(10, 3), nullable=False),
        sa.Column('distance_m', sa.Numeric(10, 2), nullable=False),
        sa.Column('avg_speed_mps', sa.Numeric(7, 4), nullable=False),
        sa.Column('min_speed_mps', sa.Numeric(7, 4), nullable=True),
        sa.Column('max_speed_mps', sa.Numeric(7, 4), nullable=False),
        sa.Column('vertical_m', sa.Numeric(8, 2), nullable=True),
        sa.Column('min_altitude_m', sa.Numeric(9, 2), nullable=True),
        sa.Column('max_altitude_m', sa.Numeric(9, 2), nullable=True),
        sa.Column('min_lat', sa.Float(precision=53), nullable=True),
        sa.Column('max_lat', sa.Float(precision=53), nullable=True),
        sa.Column('min_long', sa.Float(precision=53), nullable=True),
        sa.Column('max_long', sa.Float(precision=53), nullable=True),
        sa.Column('top_speed_lat', sa.Float(precision=53), nullable=True),
        sa.Column('top_speed_long', sa.Float(precision=53), nullable=True),
        sa.Column('top_speed_alt_m', sa.Numeric(9, 2), nullable=True),
        sa.Column('time_of_day', sa.SmallInteger(), nullable=True),
        sa.Column('external_track_id', sa.Text(), nullable=True),
        sa.Column('source', sa.Text(), nullable=False),
        sa.Column(
            'created_at',
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text('now()'),
        ),
        sa.CheckConstraint("action_type IN ('lift','run')", name='ck_ride_session_actions_action_type'),
        sa.CheckConstraint('sequence_index >= 1', name='ck_ride_session_actions_sequence_index'),
        sa.CheckConstraint('time_of_day IN (1,2,3)', name='ck_ride_session_actions_time_of_day'),
        sa.CheckConstraint(
            "source IN ('live_analyzer','slopes_import','manual')",
            name='ck_ride_session_actions_source',
        ),
        sa.ForeignKeyConstraint(['session_id'], ['ride_sessions.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint(
            'session_id',
            'action_type',
            'sequence_index',
            name='uq_ride_session_actions_session_id_action_type_sequence_index',
        ),
    )
    op.create_index(
        'ix_ride_session_actions_session_id_started_at',
        'ride_session_actions',
        ['session_id', 'started_at'],
        unique=False,
    )

    op.create_table(
        'ride_session_overrides',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('session_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('started_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('ended_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('motion_state', sa.Text(), nullable=False),
        sa.Column('created_by', sa.Text(), nullable=False),
        sa.Column(
            'created_at',
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text('now()'),
        ),
        sa.CheckConstraint("motion_state IN ('run','lift','ignore')", name='ck_ride_session_overrides_motion_state'),
        sa.CheckConstraint("created_by IN ('user','importer')", name='ck_ride_session_overrides_created_by'),
        sa.ForeignKeyConstraint(['session_id'], ['ride_sessions.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        'ix_ride_session_overrides_session_id_started_at',
        'ride_session_overrides',
        ['session_id', 'started_at'],
        unique=False,
    )

    op.create_table(
        'resort_lifts',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('resort_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('name', sa.Text(), nullable=False),
        sa.Column('lift_type', sa.Text(), nullable=True),
        sa.Column('polyline', sa.Text(), nullable=True),
        sa.Column('base_altitude_m', sa.Numeric(8, 2), nullable=True),
        sa.Column('top_altitude_m', sa.Numeric(8, 2), nullable=True),
        sa.Column('external_track_id', sa.Text(), nullable=True),
        sa.Column(
            'created_at',
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text('now()'),
        ),
        sa.CheckConstraint(
            "lift_type IN ('chair','gondola','surface','tbar','magic_carpet')",
            name='ck_resort_lifts_lift_type',
        ),
        sa.ForeignKeyConstraint(['resort_id'], ['resorts.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_resort_lifts_resort_id', 'resort_lifts', ['resort_id'], unique=False)
    op.create_index(
        'ix_resort_lifts_external_track_id',
        'resort_lifts',
        ['external_track_id'],
        unique=False,
    )

    op.drop_table('session_point_analytics')

    op.drop_column('session_points', 'motion_state')
    op.drop_column('session_points', 'quality_class')
    op.drop_column('session_points', 'quality_score')
    op.drop_column('session_points', 'quality_reason')
    op.drop_column('session_points', 'filtered_latitude')
    op.drop_column('session_points', 'filtered_longitude')
    op.drop_column('session_points', 'filtered_altitude_m')
    op.drop_column('session_points', 'fused_speed_mps')
    op.drop_column('session_points', 'derived_speed_mps')
    op.drop_column('session_points', 'distance_delta_m')
    op.drop_column('session_points', 'accepted_for_analytics')

    op.execute('DROP TYPE IF EXISTS motion_state')
    op.execute('DROP TYPE IF EXISTS quality_class')

    op.execute('TRUNCATE session_points, ride_sessions RESTART IDENTITY CASCADE')

    op.add_column(
        'ride_sessions',
        sa.Column(
            'source',
            sa.Text(),
            nullable=False,
            server_default=sa.text("'live_recording'"),
        ),
    )
    op.create_check_constraint(
        'ck_ride_sessions_source',
        'ride_sessions',
        "source IN ('live_recording','slopes_import','imported_other')",
    )
    op.add_column('ride_sessions', sa.Column('external_identifier', sa.Text(), nullable=True))
    op.add_column(
        'ride_sessions',
        sa.Column('conditions', _session_conditions_enum_existing, nullable=True),
    )
    op.add_column(
        'ride_sessions',
        sa.Column(
            'sport',
            sa.Text(),
            nullable=False,
            server_default=sa.text("'snowboard'"),
        ),
    )
    op.create_check_constraint(
        'ck_ride_sessions_sport',
        'ride_sessions',
        "sport IN ('snowboard','ski')",
    )
    op.add_column('ride_sessions', sa.Column('altitude_offset_m', sa.Numeric(6, 2), nullable=True))
    op.add_column('ride_sessions', sa.Column('peak_altitude_m', sa.Numeric(8, 2), nullable=True))
    op.add_column('ride_sessions', sa.Column('center_lat', sa.Float(precision=53), nullable=True))
    op.add_column('ride_sessions', sa.Column('center_long', sa.Float(precision=53), nullable=True))
    op.add_column('ride_sessions', sa.Column('descent_distance_m', sa.Numeric(10, 2), nullable=False))
    op.add_column('ride_sessions', sa.Column('descent_duration_s', sa.Numeric(10, 3), nullable=False))
    op.add_column('ride_sessions', sa.Column('descent_vertical_m', sa.Numeric(8, 2), nullable=False))
    op.add_column('ride_sessions', sa.Column('lift_distance_m', sa.Numeric(10, 2), nullable=False))
    op.add_column('ride_sessions', sa.Column('lift_duration_s', sa.Numeric(10, 3), nullable=False))
    op.add_column('ride_sessions', sa.Column('lift_vertical_m', sa.Numeric(8, 2), nullable=False))
    op.add_column('ride_sessions', sa.Column('avg_descent_speed_mps', sa.Numeric(7, 4), nullable=False))
    op.add_column('ride_sessions', sa.Column('total_duration_s', sa.Numeric(10, 3), nullable=False))
    op.add_column('ride_sessions', sa.Column('processed_by_version', sa.Text(), nullable=True))
    op.add_column('ride_sessions', sa.Column('processed_at', sa.DateTime(timezone=True), nullable=True))
    op.create_index(
        'ix_ride_sessions_external_identifier_unique',
        'ride_sessions',
        ['external_identifier'],
        unique=True,
        postgresql_where=sa.text('external_identifier IS NOT NULL'),
    )

    op.drop_column('ride_sessions', 'distance_m')
    op.drop_column('ride_sessions', 'avg_speed_mps')
    op.drop_column('ride_sessions', 'elevation_gain_m')
    op.drop_column('ride_sessions', 'elevation_loss_m')
    op.drop_column('ride_sessions', 'duration_s')


def downgrade() -> None:
    op.drop_table('ride_session_overrides')
    op.drop_table('ride_session_actions')
    op.drop_table('resort_lifts')

    op.drop_index('ix_ride_sessions_external_identifier_unique', table_name='ride_sessions')

    op.drop_column('ride_sessions', 'processed_at')
    op.drop_column('ride_sessions', 'processed_by_version')
    op.drop_column('ride_sessions', 'total_duration_s')
    op.drop_column('ride_sessions', 'avg_descent_speed_mps')
    op.drop_column('ride_sessions', 'lift_vertical_m')
    op.drop_column('ride_sessions', 'lift_duration_s')
    op.drop_column('ride_sessions', 'lift_distance_m')
    op.drop_column('ride_sessions', 'descent_vertical_m')
    op.drop_column('ride_sessions', 'descent_duration_s')
    op.drop_column('ride_sessions', 'descent_distance_m')
    op.drop_column('ride_sessions', 'center_long')
    op.drop_column('ride_sessions', 'center_lat')
    op.drop_column('ride_sessions', 'peak_altitude_m')
    op.drop_column('ride_sessions', 'altitude_offset_m')
    op.drop_column('ride_sessions', 'sport')
    op.drop_column('ride_sessions', 'conditions')
    op.drop_column('ride_sessions', 'external_identifier')
    op.drop_column('ride_sessions', 'source')

    _session_conditions_enum.drop(op.get_bind(), checkfirst=True)

    _motion_state_enum.create(op.get_bind(), checkfirst=True)
    _quality_class_enum.create(op.get_bind(), checkfirst=True)

    op.create_table(
        'session_point_analytics',
        sa.Column('session_point_id', sa.BigInteger(), nullable=False),
        sa.Column('quality_class', _quality_class_enum_existing, nullable=True),
        sa.Column('quality_score', sa.Float(), nullable=True),
        sa.Column('quality_reason', sa.Text(), nullable=True),
        sa.Column('filtered_latitude', sa.Float(), nullable=True),
        sa.Column('filtered_longitude', sa.Float(), nullable=True),
        sa.Column('filtered_altitude_m', sa.Float(), nullable=True),
        sa.Column('fused_speed_mps', sa.Float(), nullable=True),
        sa.Column('derived_speed_mps', sa.Float(), nullable=True),
        sa.Column('distance_delta_m', sa.Float(), nullable=True),
        sa.Column('motion_state', _motion_state_enum_existing, nullable=True),
        sa.Column(
            'accepted_for_analytics',
            sa.Boolean(),
            nullable=False,
            server_default=sa.text('true'),
        ),
        sa.ForeignKeyConstraint(['session_point_id'], ['session_points.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('session_point_id'),
    )

    op.add_column('session_points', sa.Column('quality_class', _quality_class_enum_existing, nullable=True))
    op.add_column('session_points', sa.Column('quality_score', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('quality_reason', sa.Text(), nullable=True))
    op.add_column('session_points', sa.Column('filtered_latitude', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('filtered_longitude', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('filtered_altitude_m', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('fused_speed_mps', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('derived_speed_mps', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('distance_delta_m', sa.Float(), nullable=True))
    op.add_column('session_points', sa.Column('motion_state', _motion_state_enum_existing, nullable=True))
    op.add_column('session_points', sa.Column('accepted_for_analytics', sa.Boolean(), nullable=True))

    op.add_column('ride_sessions', sa.Column('duration_s', sa.Integer(), nullable=True))
    op.add_column('ride_sessions', sa.Column('distance_m', sa.Float(), nullable=True))
    op.add_column('ride_sessions', sa.Column('avg_speed_mps', sa.Float(), nullable=True))
    op.add_column('ride_sessions', sa.Column('elevation_gain_m', sa.Integer(), nullable=True))
    op.add_column('ride_sessions', sa.Column('elevation_loss_m', sa.Integer(), nullable=True))
