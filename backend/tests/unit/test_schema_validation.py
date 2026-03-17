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


def test_session_complete_rejects_avg_speed_above_max() -> None:
    with pytest.raises(ValidationError):
        SessionCompleteRequest(
            duration_s=120,
            distance_m=500.0,
            max_speed_mps=10.0,
            avg_speed_mps=12.0,
        )


def test_session_point_input_rejects_out_of_range_latitude() -> None:
    with pytest.raises(ValidationError):
        SessionPointInput(
            t_offset_ms=0,
            latitude=120.0,
            longitude=-123.0,
        )


def test_session_points_batch_requires_at_least_one_point() -> None:
    with pytest.raises(ValidationError):
        SessionPointsBatchRequest(points=[])
