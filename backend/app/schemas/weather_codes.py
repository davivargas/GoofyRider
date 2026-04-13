from collections.abc import Sequence
from typing import cast


def _to_optional_float(value: object) -> float | None:
    if value is None:
        return None
    if not isinstance(value, (int, float, str, bytes, bytearray)):
        raise ValueError("Weather numeric fields must be numbers.")
    return float(value)


def weather_code_to_text(raw_code: object) -> str | None:
    if raw_code is None:
        return None

    if not isinstance(raw_code, (int, float, str, bytes, bytearray)):
        raise ValueError("Weather weather_code must be numeric.")

    code = int(raw_code)
    if code == 0:
        return "Clear"
    if code in {1, 2, 3}:
        return "Partly cloudy"
    if code in {45, 48}:
        return "Fog"
    if code in {51, 53, 55, 56, 57}:
        return "Drizzle"
    if code in {61, 63, 65, 66, 67, 80, 81, 82}:
        return "Rain"
    if code in {71, 73, 75, 77, 85, 86}:
        return "Snow"
    if code in {95, 96, 99}:
        return "Thunderstorm"
    return "Mixed"


def _as_object_sequence(value: object) -> Sequence[object]:
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        sequence_value = cast(Sequence[object], value)
        return tuple(sequence_value)
    return ()
