"""resort catalog source records, overrides, provenance

Revision ID: 0016_resort_catalog_sources
Revises: 0015_analyzer_output_fields
Create Date: 2026-09-19 12:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0016_resort_catalog_sources"
down_revision: Union[str, None] = "0015_analyzer_output_fields"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_LEGACY_PAYLOAD_SQL = """
jsonb_strip_nulls(jsonb_build_object(
    'legacy', true,
    'name', name, 'country', country, 'region', region, 'city', city,
    'latitude', latitude, 'longitude', longitude,
    'elevation_base_m', elevation_base_m, 'elevation_top_m', elevation_top_m
))
"""


def upgrade() -> None:
    op.create_table(
        "resort_source_records",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("external_id", sa.Text(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("content_hash", sa.Text(), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("snapshot_built_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("missing_since", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resort_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("match_status", sa.Text(), nullable=False),
        sa.Column("match_method", sa.Text(), nullable=True),
        sa.Column("match_score", sa.Float(), nullable=True),
        sa.Column("match_candidates", postgresql.JSONB(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["resort_id"], ["resorts.id"], ondelete="SET NULL"),
        sa.UniqueConstraint("source", "external_id", name="uq_resort_source_records_source_ext"),
        sa.CheckConstraint(
            "source IN ('openskidata','ski_api')", name="ck_resort_source_records_source"
        ),
        sa.CheckConstraint(
            "match_status IN ('linked','pending_review','rejected')",
            name="ck_resort_source_records_match_status",
        ),
        sa.CheckConstraint(
            "match_method IS NULL OR match_method IN ('primary','auto','manual','legacy')",
            name="ck_resort_source_records_match_method",
        ),
    )
    op.create_index(
        "ix_resort_source_records_resort_id", "resort_source_records", ["resort_id"]
    )
    op.create_index(
        "ix_resort_source_records_source_status",
        "resort_source_records",
        ["source", "match_status"],
    )

    op.create_table(
        "resort_field_overrides",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("resort_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("field", sa.Text(), nullable=False),
        sa.Column("value", postgresql.JSONB(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["resort_id"], ["resorts.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("resort_id", "field", name="uq_resort_field_overrides_resort_field"),
        sa.CheckConstraint(
            "field IN ('name','country','country_code','region','region_code','city',"
            "'latitude','longitude','elevation_base_m','elevation_top_m','is_active')",
            name="ck_resort_field_overrides_field",
        ),
    )

    op.add_column("resorts", sa.Column("boundary", postgresql.JSONB(), nullable=True))
    op.add_column("resorts", sa.Column("bbox_min_lat", sa.Float(), nullable=True))
    op.add_column("resorts", sa.Column("bbox_min_lon", sa.Float(), nullable=True))
    op.add_column("resorts", sa.Column("bbox_max_lat", sa.Float(), nullable=True))
    op.add_column("resorts", sa.Column("bbox_max_lon", sa.Float(), nullable=True))
    op.add_column("resorts", sa.Column("country_code", sa.String(length=2), nullable=True))
    op.add_column("resorts", sa.Column("region_code", sa.String(length=10), nullable=True))
    op.add_column(
        "resorts",
        sa.Column(
            "name_aliases",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
    )
    op.add_column(
        "resorts",
        sa.Column(
            "field_provenance",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )
    op.add_column(
        "resorts", sa.Column("last_merged_at", sa.DateTime(timezone=True), nullable=True)
    )

    # Legacy rows: one linked source record per (external_source, external_id).
    op.execute(
        f"""
        INSERT INTO resort_source_records (
            id, source, external_id, payload, content_hash, fetched_at, resort_id,
            match_status, match_method
        )
        SELECT gen_random_uuid(), external_source, external_id, {_LEGACY_PAYLOAD_SQL},
               encode(sha256(convert_to(({_LEGACY_PAYLOAD_SQL})::text, 'UTF8')), 'hex'),
               COALESCE(last_source_sync_at, now()), id, 'linked', 'legacy'
        FROM resorts
        WHERE external_source IN ('openskidata','ski_api') AND external_id IS NOT NULL
        """
    )
    op.execute(
        """
        UPDATE resorts SET field_provenance = jsonb_strip_nulls(jsonb_build_object(
            'name', external_source, 'country', external_source, 'region', external_source,
            'city', CASE WHEN city IS NULL THEN NULL ELSE external_source END,
            'latitude', CASE WHEN latitude IS NULL THEN NULL ELSE external_source END,
            'longitude', CASE WHEN longitude IS NULL THEN NULL ELSE external_source END,
            'elevation_base_m',
                CASE WHEN elevation_base_m IS NULL THEN NULL ELSE external_source END,
            'elevation_top_m',
                CASE WHEN elevation_top_m IS NULL THEN NULL ELSE external_source END
        ))
        WHERE external_source IN ('openskidata','ski_api') AND external_id IS NOT NULL
        """
    )

    op.drop_constraint("uq_resorts_external_source_external_id", "resorts", type_="unique")
    op.drop_constraint("uq_resorts_name_country_region", "resorts", type_="unique")
    op.drop_column("resorts", "last_source_sync_at")
    op.drop_column("resorts", "external_id")
    op.drop_column("resorts", "external_source")

    op.add_column(
        "resort_lifts",
        sa.Column("source", sa.Text(), nullable=False, server_default=sa.text("'overpass'")),
    )
    op.add_column("resort_lifts", sa.Column("status", sa.Text(), nullable=True))
    op.add_column(
        "resort_lifts",
        sa.Column("source_record_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "fk_resort_lifts_source_record_id",
        "resort_lifts",
        "resort_source_records",
        ["source_record_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_check_constraint(
        "ck_resort_lifts_source", "resort_lifts", "source IN ('overpass','openskidata')"
    )
    op.create_index(
        "ix_resort_lifts_resort_track_unique",
        "resort_lifts",
        ["resort_id", "external_track_id"],
        unique=True,
        postgresql_where=sa.text("external_track_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_resort_lifts_resort_track_unique", table_name="resort_lifts")
    op.drop_constraint("ck_resort_lifts_source", "resort_lifts", type_="check")
    op.drop_constraint("fk_resort_lifts_source_record_id", "resort_lifts", type_="foreignkey")
    op.drop_column("resort_lifts", "source_record_id")
    op.drop_column("resort_lifts", "status")
    op.drop_column("resort_lifts", "source")

    op.add_column("resorts", sa.Column("external_source", sa.String(length=50), nullable=True))
    op.add_column("resorts", sa.Column("external_id", sa.String(length=160), nullable=True))
    op.add_column(
        "resorts", sa.Column("last_source_sync_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.execute(
        """
        UPDATE resorts r
        SET external_source = s.source, external_id = s.external_id,
            last_source_sync_at = s.fetched_at
        FROM resort_source_records s
        WHERE s.resort_id = r.id AND s.match_method = 'legacy'
        """
    )
    op.create_unique_constraint(
        "uq_resorts_external_source_external_id", "resorts", ["external_source", "external_id"]
    )
    # May fail if OpenSkiData imported same-name areas in one region; delete duplicates first.
    op.create_unique_constraint(
        "uq_resorts_name_country_region", "resorts", ["name", "country", "region"]
    )

    op.drop_column("resorts", "last_merged_at")
    op.drop_column("resorts", "field_provenance")
    op.drop_column("resorts", "name_aliases")
    op.drop_column("resorts", "region_code")
    op.drop_column("resorts", "country_code")
    op.drop_column("resorts", "bbox_max_lon")
    op.drop_column("resorts", "bbox_max_lat")
    op.drop_column("resorts", "bbox_min_lon")
    op.drop_column("resorts", "bbox_min_lat")
    op.drop_column("resorts", "boundary")

    op.drop_table("resort_field_overrides")
    op.drop_index("ix_resort_source_records_source_status", table_name="resort_source_records")
    op.drop_index("ix_resort_source_records_resort_id", table_name="resort_source_records")
    op.drop_table("resort_source_records")
