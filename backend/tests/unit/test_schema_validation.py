import pytest
from pydantic import ValidationError

from app.schemas.auth import RegisterRequest
from app.schemas.session import SessionCompleteRequest
from app.schemas.session import SessionPointInput
from app.schemas.session import SessionPointsBatchRequest


def test_register_request_normalizes_email_and_display_name() -> None:
    payload = RegisterRequest(
        email="  STUDENT@EXAMPLE.COM  ",
        password="strongpass123",
        display_name="  Rider One  ",
    )

    assert payload.email == "student@example.com"
    assert payload.display_name == "Rider One"


def test_register_request_rejects_invalid_email() -> None:
    with pytest.raises(ValidationError):
        RegisterRequest(
            email="invalid-email",
            password="strongpass123",
            display_name="Rider One",
        )


def test_session_complete_allows_avg_speed_above_max() -> None:
    payload = SessionCompleteRequest(
        duration_s=120,
        distance_m=500.0,
        max_speed_mps=10.0,
        avg_speed_mps=12.0,
    )

    assert payload.duration_s == 120
    assert payload.distance_m == 500.0
    assert payload.max_speed_mps == 10.0
    assert payload.avg_speed_mps == 12.0


def test_session_point_input_rejects_out_of_range_latitude() -> None:
    with pytest.raises(ValidationError) as exc_info:
        SessionPointInput(
            t_offset_ms=0,
            latitude=120.0,
            longitude=-123.0,
        )

    errors = exc_info.value.errors()
    assert len(errors) == 1
    assert errors[0]["loc"] == ("latitude",)
    assert errors[0]["type"] == "less_than_equal"
    assert "less than or equal to 90" in errors[0]["msg"]


def test_session_point_input_rejects_negative_optional_accuracy() -> None:
    with pytest.raises(ValidationError) as exc_info:
        SessionPointInput(
            t_offset_ms=0,
            latitude=50.0,
            longitude=-123.0,
            accuracy_m=-0.1,
        )

    errors = exc_info.value.errors()
    assert len(errors) == 1
    assert errors[0]["loc"] == ("accuracy_m",)
    assert errors[0]["type"] == "greater_than_equal"
    assert "greater than or equal to 0" in errors[0]["msg"]


def test_session_points_batch_requires_at_least_one_point() -> None:
    with pytest.raises(ValidationError):
        SessionPointsBatchRequest(points=[])
