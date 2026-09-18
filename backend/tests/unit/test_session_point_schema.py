from pydantic import ValidationError as PydanticValidationError
import pytest

from app.schemas.session_point import SessionPointInput


def _point(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {"t_offset_ms": 0, "latitude": 49.4, "longitude": -123.0}
    base.update(overrides)
    return base


def test_pressure_is_optional_and_stored() -> None:
    assert SessionPointInput(**_point()).pressure_hpa is None
    assert SessionPointInput(**_point(pressure_hpa=898.7)).pressure_hpa == 898.7


@pytest.mark.parametrize("value", [299.9, 1100.1])
def test_pressure_outside_the_physical_range_is_rejected(value: float) -> None:
    with pytest.raises(PydanticValidationError):
        SessionPointInput(**_point(pressure_hpa=value))
