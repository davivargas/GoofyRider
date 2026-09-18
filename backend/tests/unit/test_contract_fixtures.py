import json
from pathlib import Path

from app.schemas.session import SessionDetailResponse
from app.schemas.session_point import SessionPointInput

_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "contracts"


def test_point_batch_fixture_parses_and_carries_pressure() -> None:
    payload = json.loads((_DIR / "session_point_batch.json").read_text(encoding="utf-8"))
    points = [SessionPointInput(**p) for p in payload["points"]]
    assert points[0].pressure_hpa == 898.7
    assert points[1].pressure_hpa is None


def test_session_detail_fixture_parses_with_break_fields() -> None:
    payload = json.loads((_DIR / "session_detail.json").read_text(encoding="utf-8"))
    detail = SessionDetailResponse.model_validate(payload)
    assert detail.session.break_count == 1
    assert detail.session.break_duration_s == 240.0
    assert [a.action_type for a in detail.actions] == ["run", "lift"]


def test_mobile_copy_is_identical() -> None:
    mobile = Path(__file__).resolve().parents[3] / "mobile" / "test" / "fixtures" / "contracts"
    for name in ("session_point_batch.json", "session_detail.json"):
        assert (mobile / name).read_bytes() == (_DIR / name).read_bytes(), name
