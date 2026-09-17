from datetime import UTC
from datetime import datetime
from datetime import timedelta

from app.services.analysis.types import RawPoint

BASE_TIME = datetime(2026, 2, 1, 10, 0, 0, tzinfo=UTC)
DEG_LAT_PER_M = 1.0 / 110_540.0


def point(
    second: float,
    *,
    north_m: float = 0.0,
    east_m: float = 0.0,
    altitude_m: float | None = 1000.0,
    speed_mps: float | None = 0.0,
    accuracy_m: float | None = 5.0,
    vertical_accuracy_m: float | None = None,
    speed_accuracy_mps: float | None = None,
    pressure_hpa: float | None = None,
) -> RawPoint:
    return RawPoint(
        t_offset_ms=int(second * 1000),
        recorded_at=BASE_TIME + timedelta(seconds=second),
        latitude=49.4 + north_m * DEG_LAT_PER_M,
        longitude=-123.0 + east_m / (111_320.0 * 0.6508),
        altitude_m=altitude_m,
        speed_mps=speed_mps,
        accuracy_m=accuracy_m,
        vertical_accuracy_m=vertical_accuracy_m,
        speed_accuracy_mps=speed_accuracy_mps,
        pressure_hpa=pressure_hpa,
    )


def descent(
    start_s: int,
    seconds: int,
    *,
    speed: float = 8.0,
    drop_per_s: float = 3.0,
    north0: float = 0.0,
    alt0: float = 1000.0,
) -> list[RawPoint]:
    """One point per second moving south (decreasing north) while losing altitude."""
    return [
        point(
            start_s + i,
            north_m=north0 - speed * i,
            altitude_m=alt0 - drop_per_s * i,
            speed_mps=speed,
        )
        for i in range(seconds)
    ]


def standstill(
    start_s: int, seconds: int, *, north: float, alt: float, every_s: int = 1
) -> list[RawPoint]:
    return [
        point(start_s + i, north_m=north, altitude_m=alt, speed_mps=0.0)
        for i in range(0, seconds, every_s)
    ]


def climb(
    start_s: int,
    seconds: int,
    *,
    speed: float = 4.0,
    gain_per_s: float = 1.5,
    north0: float = 0.0,
    alt0: float = 700.0,
) -> list[RawPoint]:
    """One point per second moving north in a straight line while gaining altitude."""
    return [
        point(
            start_s + i,
            north_m=north0 + speed * i,
            altitude_m=alt0 + gain_per_s * i,
            speed_mps=speed,
        )
        for i in range(seconds)
    ]
