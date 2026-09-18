"""Every tunable constant of the analyzer, in one frozen dataclass."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from dataclasses import fields
from dataclasses import replace

from app.services.exceptions import ValidationError


@dataclass(frozen=True)
class AnalyzerConfig:
    # signal conditioning (spec section 5)
    accuracy_reject_m: float = 30.0
    jump_reject_mps: float = 40.0
    speed_accuracy_trust_mps: float = 3.0
    still_mps: float = 0.8
    bridge_max_s: int = 30
    speed_window_s: int = 5
    gps_alt_window_s: int = 15
    baro_alt_window_s: int = 5
    baro_offset_tau_s: float = 300.0
    vrate_half_window_s: int = 6
    heading_window_s: int = 10
    # decoder emissions (spec section 7)
    descent_fast_mps: float = 2.0
    descent_slow_mps: float = 0.8
    descent_vrate_mps: float = -0.3
    stop_fast_mps: float = 1.5
    lift_vrate_mps: float = 0.1
    lift_max_mps: float = 10.0
    lift_heading_var_max: float = 0.5
    # decoder transition penalties (natural-log units)
    switch_descent_stop: float = -4.0
    switch_stop_descent: float = -4.0
    switch_stop_lift: float = -5.0
    switch_lift_stop: float = -5.0
    switch_descent_lift: float = -9.0
    switch_lift_descent: float = -6.0
    # lift matching (spec section 6)
    lift_radius_m: float = 45.0
    lift_near_factor: float = 1.5
    lift_bearing_deg: float = 30.0
    lift_bearing_half_window_s: int = 5
    lift_bearing_min_move_m: float = 3.0
    lift_riding_min_mps: float = 0.5
    lift_gap_s: int = 150
    # Bridged seconds inside a lift span must be slower than this. Chosen equal to
    # still_mps on purpose (a stopped chair may creep); keep the two aligned when retuning.
    lift_bridge_max_mps: float = 0.8
    lift_min_duration_s: int = 30
    lift_riding_fraction: float = 0.35
    lift_min_move_m: float = 60.0
    lift_max_median_mps: float = 12.0
    lift_min_gain_m: float = 15.0
    low_gain_min_change_m: float = -2.0
    low_gain_max_median_mps: float = 3.5
    # action building (spec section 8)
    tiny_descent_m: float = 25.0
    fallback_lift_min_s: int = 60
    fallback_lift_min_gain_m: float = 20.0
    fallback_lift_max_median_mps: float = 8.0
    area_pad_m: float = 400.0
    lift_stoppage_max_s: int = 300
    lift_stoppage_max_move_m: float = 40.0
    vehicle_mps: float = 28.0
    vehicle_min_s: int = 10
    flat_fast_max_change_m: float = 3.0
    flat_fast_mps: float = 8.0
    flat_fast_min_s: int = 15
    base_margin_m: float = 10.0
    unknown_split_s: int = 600
    max_in_run_break_s: int = 1200
    tail_min_drop_m: float = 3.0
    min_run_s: int = 20
    min_run_drop_m: float = 15.0
    long_stop_s: int = 120
    min_action_duration_s: float = 2.0
    spike_ratio: float = 2.0
    spike_floor_mps: float = 1.0

    def with_overrides(self, **overrides: float | int) -> AnalyzerConfig:
        # dataclasses.replace() can't statically verify a **dict of mixed
        # per-field types against the dataclass's individual field types.
        return replace(self, **overrides)  # type: ignore[arg-type]


def parse_overrides(pairs: Sequence[str]) -> dict[str, float | int]:
    """Parse `key=value` strings into typed overrides for `with_overrides`."""
    kinds = {f.name: f.type for f in fields(AnalyzerConfig)}
    parsed: dict[str, float | int] = {}
    for pair in pairs:
        key, _, raw = pair.partition("=")
        if key not in kinds or not raw:
            raise ValidationError(f"Unknown or empty analyzer override: {pair!r}")
        parsed[key] = int(float(raw)) if kinds[key] == "int" else float(raw)
    return parsed
