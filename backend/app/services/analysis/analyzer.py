"""Pure session analyzer. Call `SessionAnalyzer.analyze` to get an `AnalysisResult`."""

from __future__ import annotations

from collections.abc import Sequence

from app.services.analysis.actions import BreakStats
from app.services.analysis.actions import break_stats
from app.services.analysis.actions import build
from app.services.analysis.actions import summarize
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.hmm import decode
from app.services.analysis.lift_matching import anchor
from app.services.analysis.lift_matching import resort_area
from app.services.analysis.signal import condition
from app.services.analysis.types import IGNORE
from app.services.analysis.types import IMPORT_SOURCE
from app.services.analysis.types import LIFT
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import AnalysisResult
from app.services.analysis.types import AnalyzerInput
from app.services.analysis.types import OverrideRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import PresetAction
from app.services.exceptions import ValidationError


class SessionAnalyzer:
    """`analyzer_version` and `config` are injected; the analyzer never reads settings."""

    def __init__(self, *, analyzer_version: str, config: AnalyzerConfig | None = None) -> None:
        self._analyzer_version = analyzer_version
        self._config = config or AnalyzerConfig()

    def analyze(self, analyzer_input: AnalyzerInput) -> AnalysisResult:
        _validate_input(analyzer_input)
        config = self._config
        overrides = list(analyzer_input.preset_overrides or ())

        frame = condition(analyzer_input.points, config) if analyzer_input.points else None
        actions: list[ActionRecord] = []
        breaks = BreakStats(0, 0.0)
        if frame is not None:
            anchored = anchor(frame, analyzer_input.resort_lifts, config)
            states = decode(frame, anchored, config)
            if analyzer_input.preset_actions:
                first = min(p.started_at for p in analyzer_input.preset_actions)
                last = max(p.ended_at for p in analyzer_input.preset_actions)
                # An imported session takes its break stats from the raw decoded states,
                # before the live path's validity passes run, so imported and live break
                # counts can differ for the same track.
                breaks = break_stats(states, frame.index_at(first), frame.index_at(last), config)
            else:
                area = resort_area(analyzer_input.resort_lifts, config)
                actions, breaks = build(frame, states, anchored, overrides, config, area=area)
        if analyzer_input.preset_actions:
            actions = _actions_from_preset(analyzer_input.preset_actions)

        return AnalysisResult(
            summary=summarize(actions, analyzer_input.metadata, breaks),
            actions=actions,
            overrides=[_override_to_record(span) for span in overrides],
            analyzer_version=self._analyzer_version,
        )


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def _validate_input(analyzer_input: AnalyzerInput) -> None:
    metadata = analyzer_input.metadata
    if metadata.record_end < metadata.record_start:
        raise ValidationError("record_end must be >= record_start")

    preset_actions = analyzer_input.preset_actions or []
    for preset in preset_actions:
        if preset.action_type not in (RUN, LIFT):
            raise ValidationError(
                f"Preset action type must be 'run' or 'lift', got: {preset.action_type!r}"
            )
        if preset.ended_at < preset.started_at:
            raise ValidationError("Preset action ended_at must be >= started_at")

    for span in analyzer_input.preset_overrides or []:
        if span.motion_state not in (RUN, LIFT, IGNORE):
            raise ValidationError(
                f"Override motion_state must be run/lift/ignore, got: {span.motion_state!r}"
            )
        if span.ended_at < span.started_at:
            raise ValidationError("Override ended_at must be >= started_at")


# ---------------------------------------------------------------------------
# Import path
# ---------------------------------------------------------------------------


def _actions_from_preset(preset_actions: Sequence[PresetAction]) -> list[ActionRecord]:
    ordered = sorted(preset_actions, key=lambda a: (a.action_type, a.sequence_index))
    return [
        ActionRecord(
            action_type=preset.action_type,
            sequence_index=preset.sequence_index,
            started_at=preset.started_at,
            ended_at=preset.ended_at,
            duration_s=float(preset.duration_s),
            distance_m=float(preset.distance_m),
            avg_speed_mps=float(preset.avg_speed_mps),
            max_speed_mps=float(preset.max_speed_mps),
            min_speed_mps=_opt_float(preset.min_speed_mps),
            vertical_m=_opt_float(preset.vertical_m),
            min_altitude_m=_opt_float(preset.min_altitude_m),
            max_altitude_m=_opt_float(preset.max_altitude_m),
            min_lat=_opt_float(preset.min_lat),
            max_lat=_opt_float(preset.max_lat),
            min_long=_opt_float(preset.min_long),
            max_long=_opt_float(preset.max_long),
            top_speed_lat=_opt_float(preset.top_speed_lat),
            top_speed_long=_opt_float(preset.top_speed_long),
            top_speed_alt_m=_opt_float(preset.top_speed_alt_m),
            time_of_day=preset.time_of_day,
            external_track_id=preset.external_track_id,
            source=IMPORT_SOURCE,
        )
        for preset in ordered
    ]


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def _opt_float(value: float | None) -> float | None:
    return None if value is None else float(value)


def _override_to_record(span: OverrideSpan) -> OverrideRecord:
    return OverrideRecord(
        started_at=span.started_at,
        ended_at=span.ended_at,
        motion_state=span.motion_state,
        created_by=span.created_by,
    )
