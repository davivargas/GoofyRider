from pydantic import ValidationError
import pytest

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
    with pytest.raises(ValidationError) as exc_info:
        SessionCompleteRequest(
            duration_s=120,
            distance_m=500.0,
            max_speed_mps=10.0,
            avg_speed_mps=12.0,
        )

    errors = exc_info.value.errors()
    assert len(errors) == 1
    assert errors[0]["loc"] == ()
    assert "avg_speed_mps must be less than or equal to max_speed_mps" in errors[0]["msg"]


def test_session_complete_rejects_negative_metrics() -> None:
    with pytest.raises(ValidationError) as exc_info:
        SessionCompleteRequest(
            duration_s=-1,
            distance_m=-500.0,
            max_speed_mps=-10.0,
            avg_speed_mps=-12.0,
            elevation_gain_m=-40,
            elevation_loss_m=-300,
        )

    error_fields = {error["loc"][0] for error in exc_info.value.errors()}
    assert error_fields == {
        "duration_s",
        "distance_m",
        "max_speed_mps",
        "avg_speed_mps",
        "elevation_gain_m",
        "elevation_loss_m",
    }


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


def test_session_point_input_accepts_restore_contract_fields() -> None:
    payload = SessionPointInput(
        t_offset_ms=0,
        latitude=50.0,
        longitude=-123.0,
        recorded_at="2026-01-01T00:00:00Z",
        accepted_for_analytics=True,
    )

    assert payload.recorded_at is not None
    assert payload.accepted_for_analytics is True


def test_session_point_input_normalizes_canonical_vocabulary_fields() -> None:
    payload = SessionPointInput(
        t_offset_ms=0,
        latitude=50.0,
        longitude=-123.0,
        provider=" FusedLocationProvider ",
        quality_class="ACCEPT-LOW-CONFIDENCE",
        motion_state=" Lift Uphill ",
    )

    assert payload.provider == "fused"
    assert payload.quality_class == "accept_low_confidence"
    assert payload.motion_state == "lift_uphill"


def test_session_point_input_rejects_non_canonical_quality_or_motion_state() -> None:
    with pytest.raises(ValidationError) as exc_info:
        SessionPointInput(
            t_offset_ms=0,
            latitude=50.0,
            longitude=-123.0,
            quality_class="good",
            motion_state="moving",
        )

    error_fields = {error["loc"][0] for error in exc_info.value.errors()}
    assert error_fields == {"quality_class", "motion_state"}


def test_session_points_batch_requires_at_least_one_point() -> None:
    with pytest.raises(ValidationError):
        SessionPointsBatchRequest(points=[])
