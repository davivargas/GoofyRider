"""Copy analytics fields from session_points into session_point_analytics.

Idempotent: rows already present in session_point_analytics are skipped via
the ON CONFLICT clause. Safe to re-run after new rows arrive without the
dual-write path (shouldn't happen, but the script exists as an escape
hatch per IMPROVEMENTS_PLAN.md Phase 4 Step 4).
"""

import logging

from sqlalchemy import text

from app.core.database import get_session_local

logger = logging.getLogger(__name__)


_BACKFILL_SQL = text(
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
        sp.id,
        sp.quality_class,
        sp.quality_score,
        sp.quality_reason,
        sp.filtered_latitude,
        sp.filtered_longitude,
        sp.filtered_altitude_m,
        sp.fused_speed_mps,
        sp.derived_speed_mps,
        sp.distance_delta_m,
        sp.motion_state,
        sp.accepted_for_analytics
    FROM session_points AS sp
    LEFT JOIN session_point_analytics AS spa
        ON spa.session_point_id = sp.id
    WHERE spa.session_point_id IS NULL
    """
)


def backfill_session_point_analytics() -> int:
    db = get_session_local()()
    try:
        result = db.execute(_BACKFILL_SQL)
        inserted = result.rowcount or 0
        db.commit()
    finally:
        db.close()
    return inserted


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    inserted = backfill_session_point_analytics()
    logger.info("Backfilled %d session_point_analytics rows", inserted)


if __name__ == "__main__":
    main()
