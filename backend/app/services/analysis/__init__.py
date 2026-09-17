"""Session analysis pipeline. See docs/superpowers/specs/2026-09-13-gps-segmentation-design.md."""

from app.services.analysis.analyzer import SessionAnalyzer
from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.signal import smooth_speeds_centered_mean
from app.services.analysis.types import IGNORE
from app.services.analysis.types import LIFT
from app.services.analysis.types import RUN
from app.services.analysis.types import ActionRecord
from app.services.analysis.types import AnalysisResult
from app.services.analysis.types import AnalyzerInput
from app.services.analysis.types import OverrideRecord
from app.services.analysis.types import OverrideSpan
from app.services.analysis.types import PresetAction
from app.services.analysis.types import RawPoint
from app.services.analysis.types import ResortLift
from app.services.analysis.types import SessionMetadataInput
from app.services.analysis.types import SessionSummaryFields

__all__ = [
    "IGNORE",
    "LIFT",
    "RUN",
    "ActionRecord",
    "AnalysisResult",
    "AnalyzerConfig",
    "AnalyzerInput",
    "OverrideRecord",
    "OverrideSpan",
    "PresetAction",
    "RawPoint",
    "ResortLift",
    "SessionAnalyzer",
    "SessionMetadataInput",
    "SessionSummaryFields",
    "smooth_speeds_centered_mean",
]
