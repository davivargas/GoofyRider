import pytest

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.config import parse_overrides
from app.services.exceptions import ValidationError


def test_with_overrides_returns_a_new_config() -> None:
    base = AnalyzerConfig()
    tuned = base.with_overrides(lift_radius_m=60.0)
    assert tuned.lift_radius_m == 60.0
    assert base.lift_radius_m == 45.0


def test_parse_overrides_keeps_int_fields_int() -> None:
    parsed = parse_overrides(["bridge_max_s=45", "still_mps=0.6"])
    assert parsed == {"bridge_max_s": 45, "still_mps": 0.6}
    assert isinstance(parsed["bridge_max_s"], int)


def test_parse_overrides_rejects_unknown_keys() -> None:
    with pytest.raises(ValidationError):
        parse_overrides(["not_a_field=1"])
