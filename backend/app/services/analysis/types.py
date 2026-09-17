"""Input and output types of the session analyzer. Pure data, no behaviour."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from dataclasses import field
from datetime import datetime
import uuid

RUN = "run"
LIFT = "lift"
IGNORE = "ignore"
LIVE_SOURCE = "live_analyzer"
IMPORT_SOURCE = "slopes_import"


@dataclass(frozen=True)
class RawPoint:
    t_offset_ms: int
    recorded_at: datetime
    latitude: float
    longitude: float
    altitude_m: float | None
    speed_mps: float | None
    accuracy_m: float | None = None
    vertical_accuracy_m: float | None = None
    speed_accuracy_mps: float | None = None
    heading_deg: float | None = None
    pressure_hpa: float | None = None


@dataclass(frozen=True)
class SessionMetadataInput:
    record_start: datetime
    record_end: datetime
    resort_id: uuid.UUID | None
    source: str


@dataclass(frozen=True)
class PresetAction:
    action_type: str
    sequence_index: int
    started_at: datetime
    ended_at: datetime
    duration_s: float
    distance_m: float
    avg_speed_mps: float
    max_speed_mps: float
    min_speed_mps: float | None = None
    vertical_m: float | None = None
    min_altitude_m: float | None = None
    max_altitude_m: float | None = None
    min_lat: float | None = None
    max_lat: float | None = None
    min_long: float | None = None
    max_long: float | None = None
    top_speed_lat: float | None = None
    top_speed_long: float | None = None
    top_speed_alt_m: float | None = None
    time_of_day: int | None = None
    external_track_id: str | None = None


@dataclass(frozen=True)
class OverrideSpan:
    started_at: datetime
    ended_at: datetime
    motion_state: str
    created_by: str


@dataclass(frozen=True)
class ResortLift:
    name: str
    polyline: Sequence[tuple[float, float]]
    lift_type: str | None = None
    osm_aerialway: str | None = None
    external_track_id: str | None = None


@dataclass(frozen=True)
class ActionRecord:
    action_type: str
    sequence_index: int
    started_at: datetime
    ended_at: datetime
    duration_s: float
    distance_m: float
    avg_speed_mps: float
    max_speed_mps: float
    min_speed_mps: float | None
    vertical_m: float | None
    min_altitude_m: float | None
    max_altitude_m: float | None
    min_lat: float | None
    max_lat: float | None
    min_long: float | None
    max_long: float | None
    top_speed_lat: float | None
    top_speed_long: float | None
    top_speed_alt_m: float | None
    time_of_day: int | None
    external_track_id: str | None
    source: str
    lift_name: str | None = None


@dataclass(frozen=True)
class OverrideRecord:
    started_at: datetime
    ended_at: datetime
    motion_state: str
    created_by: str


@dataclass(frozen=True)
class SessionSummaryFields:
    total_duration_s: float
    descent_duration_s: float
    lift_duration_s: float
    descent_distance_m: float
    lift_distance_m: float
    descent_vertical_m: float
    lift_vertical_m: float
    max_speed_mps: float | None
    avg_descent_speed_mps: float | None
    peak_altitude_m: float | None
    center_lat: float | None
    center_long: float | None
    altitude_offset_m: float
    break_count: int = 0
    break_duration_s: float = 0.0


@dataclass(frozen=True)
class AnalyzerInput:
    points: list[RawPoint]
    metadata: SessionMetadataInput
    preset_actions: list[PresetAction] | None = None
    preset_overrides: list[OverrideSpan] | None = None
    resort_lifts: Sequence[ResortLift] = field(default_factory=tuple)


@dataclass(frozen=True)
class AnalysisResult:
    summary: SessionSummaryFields
    actions: list[ActionRecord]
    overrides: list[OverrideRecord]
    analyzer_version: str
