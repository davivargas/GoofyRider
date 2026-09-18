# GPS Segmentation Backend Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the new analysis pipeline to the database and API: store barometric pressure with each point, persist the analyzer's new output fields, feed the resort lift catalog into analysis, import that catalog from OpenStreetMap, and re-analyze stored sessions.

**Architecture:** Two Alembic revisions (0014, 0015) and matching model and schema changes; `SessionService` gains a lift repository and passes catalog lifts to `SessionAnalyzer`; a new `OsmLiftCatalogService` with an injectable `httpx.Client` fills `resort_lifts` through a repository upsert; two scripts (`import_resort_lifts`, `reanalyze_sessions`) drive the operations. Plan 2 of 3; plan 1 (the analyzer package) must be merged first, plan 3 (mobile) follows.

**Tech Stack:** FastAPI, SQLAlchemy 2.0 typed models, Alembic, Pydantic v2, httpx, pytest against the `goofyrider_test` database.

**Spec:** `docs/superpowers/specs/2026-09-13-gps-segmentation-design.md` (sections 3, 4.2, 6 last two paragraphs, 8 last paragraph, 10, 11 bind this plan).

## Global Constraints

- Work on the branch the controller names (the analyzer branch, after plan 1's final review). Run `git branch --show-current` before every commit. Never run `git stash`, `git checkout`, `git switch`, `git restore`, `git reset`, `git clean`, `git merge`, or `git rebase`; compare against a baseline with `git show <rev>:<path>` or `git diff <rev>`. Stage with explicit `git add <paths>`.
- Layering: `api -> services -> repositories -> models`. Routers stay thin. Services raise `ServiceError` subclasses. Only repositories touch SQLAlchemy sessions; a new repository method is added to `app/repositories/protocols.py` first. External HTTP lives in a service with an injectable `httpx.Client` and translates failures to `ServiceUnavailableError` or `ValidationError`.
- Every schema change gets exactly one new Alembic revision; numbering is sequential; `0005` stays absent. Revisions here: `0014_session_point_pressure` and `0015_analyzer_output_fields`. Use SQLAlchemy 2.0 typed columns.
- Settings are read through `get_settings().<attribute>`; new settings go into `AppSettings`, `docker-compose.yml`, and `.env.example`.
- Contract change discipline (CLAUDE.md): `SessionPointInput` and `SessionSummary` change here, so this plan also creates the shared contract fixtures the mobile plan consumes.
- Tests: unit tests for logic; for each new endpoint-visible behaviour at least one QA happy path and one negative path; database-backed tests run only against `goofyrider_test` (build `DATABASE_URL` as shown in Task 1 Step 8; never print `.env`). Tests never perform network I/O: the Overpass service is tested with `httpx.MockTransport` and the recorded fixtures in `tests/fixtures/osm/`.
- Quality gates for touched files: `ruff check`, `ruff format --check`, `mypy` clean (the repo has older ruff and mypy errors elsewhere; leave them). `logging.getLogger(__name__)` in services and repositories; scripts may `print` their summary.
- Never expose `lift_name` in the API in this plan; it is stored only.
- End every commit message with a blank line and then `Claude-Session: https://claude.ai/code/session_019X8gVKYhkwgWtUPFHdpuDd`.

## File Structure

| File | Responsibility |
|---|---|
| `backend/alembic/versions/0014_session_point_pressure.py` | `session_points.pressure_hpa` |
| `backend/alembic/versions/0015_analyzer_output_fields.py` | `resort_lifts.osm_aerialway`, `ride_session_actions.lift_name`, `ride_sessions.break_count`, `ride_sessions.break_duration_s` |
| `backend/app/models/session_point.py`, `resort_lift.py`, `ride_session_action.py`, `ride_session.py` | matching columns |
| `backend/app/schemas/session_point.py`, `session.py` | `pressure_hpa`; `break_count`, `break_duration_s` |
| `backend/app/services/session_service.py` | pressure through to storage and the analyzer; lifts into the analyzer; `reanalyze_session` |
| `backend/app/core/dependencies/resorts.py`, `sessions.py` | `get_resort_lift_repository`; inject into `SessionService` |
| `backend/app/repositories/protocols.py`, `resort_lift_repository.py`, `resort_repository.py`, `ride_session_repository.py` | `upsert_by_external_track_id`, `get_by_name`, `list_needing_reanalysis` |
| `backend/app/services/osm_lift_catalog_service.py` | Overpass fetch and import |
| `backend/app/core/config.py`, `docker-compose.yml`, `.env.example` | `OVERPASS_BASE_URL`, `OVERPASS_TIMEOUT_SECONDS`, new analyzer version |
| `backend/app/scripts/import_resort_lifts.py`, `reanalyze_sessions.py`, `sync_contract_fixtures.py` | operations |
| `backend/tests/fixtures/contracts/session_point_batch.json`, `session_detail.json` | shared contract fixtures |
| `README.md`, `docs/ARCHITECTURE_SUMMARY.md`, `backend/tests/TEST_PLAN.md` | docs |

---

### Task 1: Barometric pressure on the point contract

**Files:**
- Create: `backend/alembic/versions/0014_session_point_pressure.py`
- Modify: `backend/app/models/session_point.py` (after `bearing_accuracy_deg`), `backend/app/schemas/session_point.py`, `backend/app/services/session_service.py` (`_build_point_with_analytics`, `_to_raw_point`)
- Test: `backend/tests/unit/test_session_point_schema.py` (new), `backend/tests/qa/test_sessions_qa.py` (append)

**Interfaces:**
- Produces: `SessionPointInput.pressure_hpa: float | None` (300 to 1100), `SessionPointPublic.pressure_hpa`, `SessionPoint.pressure_hpa` column, and `RawPoint` now receives `speed_accuracy_mps`, `heading_deg`, `pressure_hpa` from stored points.

- [ ] **Step 1: Write the failing schema test**

```python
# backend/tests/unit/test_session_point_schema.py
import pytest
from pydantic import ValidationError as PydanticValidationError

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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tests/unit/test_session_point_schema.py -q`
Expected: the first test fails with `AttributeError: 'SessionPointInput' object has no attribute 'pressure_hpa'` (or a pydantic error on the unknown field).

- [ ] **Step 3: Migration, model, schema**

```python
# backend/alembic/versions/0014_session_point_pressure.py
"""session point pressure

Revision ID: 0014_session_point_pressure
Revises: 0013_refresh_tokens
Create Date: 2026-09-17 12:00:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

revision: str = "0014_session_point_pressure"
down_revision: Union[str, None] = "0013_refresh_tokens"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("session_points", sa.Column("pressure_hpa", sa.Numeric(7, 2), nullable=True))


def downgrade() -> None:
    op.drop_column("session_points", "pressure_hpa")
```

Model, after `bearing_accuracy_deg` in `backend/app/models/session_point.py` (same style as the neighbouring numeric columns):

```python
    pressure_hpa: Mapped[float | None] = mapped_column(
        Numeric(7, 2, asdecimal=False),
        nullable=True,
    )
```

Schema, in `SessionPointInput` after `bearing_accuracy_deg` and in `SessionPointPublic` after `bearing_accuracy_deg`:

```python
    pressure_hpa: float | None = Field(default=None, ge=300, le=1100)
```
```python
    pressure_hpa: float | None
```

- [ ] **Step 4: Service plumbing**

In `_build_point_with_analytics` add `pressure_hpa=point.pressure_hpa,` after `bearing_accuracy_deg=point.bearing_accuracy_deg,`. Replace `_to_raw_point`:

```python
def _to_raw_point(point: SessionPoint) -> RawPoint:
    return RawPoint(
        t_offset_ms=point.t_offset_ms,
        recorded_at=point.recorded_at,
        latitude=point.latitude,
        longitude=point.longitude,
        altitude_m=point.altitude_m,
        speed_mps=point.speed_mps,
        accuracy_m=point.accuracy_m,
        vertical_accuracy_m=point.vertical_accuracy_m,
        speed_accuracy_mps=point.speed_accuracy_mps,
        heading_deg=point.heading_deg,
        pressure_hpa=point.pressure_hpa,
    )
```

- [ ] **Step 5: QA tests**

Append to `backend/tests/qa/test_sessions_qa.py`, reusing that file's existing helpers for creating a session and posting a batch (read the file first and follow its helper names; the point dict below is the payload shape):

```python
def test_points_batch_stores_pressure(client, register_user, create_resort, db) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Pressure Resort")
    created = client.post("/v1/sessions", json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"}, headers=headers)
    assert created.status_code == 201
    session_id = created.json()["id"]
    points = [
        {"t_offset_ms": 0, "latitude": 49.4, "longitude": -123.0, "altitude_m": 1000.0, "speed_mps": 1.0, "pressure_hpa": 898.7},
        {"t_offset_ms": 1000, "latitude": 49.4001, "longitude": -123.0, "altitude_m": 999.0, "speed_mps": 1.0},
    ]
    response = client.post(f"/v1/sessions/{session_id}/points:batch", json={"points": points}, headers=headers)
    assert response.status_code == 200
    stored = db.query(SessionPoint).filter(SessionPoint.session_id == uuid.UUID(session_id)).order_by(SessionPoint.t_offset_ms).all()
    assert [p.pressure_hpa for p in stored] == [898.7, None]


def test_points_batch_rejects_impossible_pressure(client, register_user, create_resort) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Pressure Resort 2")
    created = client.post("/v1/sessions", json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"}, headers=headers)
    session_id = created.json()["id"]
    bad = [{"t_offset_ms": 0, "latitude": 49.4, "longitude": -123.0, "pressure_hpa": 42.0}]
    response = client.post(f"/v1/sessions/{session_id}/points:batch", json={"points": bad}, headers=headers)
    assert response.status_code == 422
```

Add `import uuid` and `from app.models.session_point import SessionPoint` to the file's imports if missing.

- [ ] **Step 6: Apply the migration to the test database and run the tests**

```bash
export DATABASE_URL="$(grep '^DATABASE_URL=' ../.env | cut -d= -f2- | sed 's#/goofyrider$#/goofyrider_test#')"
alembic upgrade head
python -m pytest tests/unit/test_session_point_schema.py tests/qa/test_sessions_qa.py -q
```
Expected: all pass. (If `../.env` is not where the checkout keeps it, the controller's dispatch names the absolute path; never print the URL.)

- [ ] **Step 7: Gates and commit**

```bash
ruff check alembic/versions/0014_session_point_pressure.py app/models/session_point.py app/schemas/session_point.py app/services/session_service.py tests/unit/test_session_point_schema.py tests/qa/test_sessions_qa.py
ruff format --check <same paths>
mypy app/models/session_point.py app/schemas/session_point.py app/services/session_service.py
git add <same paths>
git commit -m "feat(backend): store barometric pressure with session points"
```

---

### Task 2: Analyzer output fields

**Files:**
- Create: `backend/alembic/versions/0015_analyzer_output_fields.py`
- Modify: `backend/app/models/resort_lift.py` (after `lift_type`), `backend/app/models/ride_session_action.py` (after `external_track_id`), `backend/app/models/ride_session.py` (after `total_duration_s`), `backend/app/schemas/session.py` (`SessionSummary` after `total_duration_s`), `backend/app/services/session_service.py` (`_summary_to_fields`, `_to_action_model`)
- Test: `backend/tests/unit/test_session_service_mappers.py` (new), `backend/tests/qa/test_sessions_analyze_override_qa.py` (append)

**Interfaces:**
- Produces: `SessionSummary.break_count: int`, `SessionSummary.break_duration_s: float`; columns `ride_sessions.break_count` (integer, default 0), `ride_sessions.break_duration_s` (numeric, default 0), `ride_session_actions.lift_name` (text, nullable), `resort_lifts.osm_aerialway` (text, nullable).

- [ ] **Step 1: Write the failing mapper test**

```python
# backend/tests/unit/test_session_service_mappers.py
from datetime import UTC
from datetime import datetime

from app.services.analysis import ActionRecord
from app.services.analysis import SessionSummaryFields
from app.services.session_service import _summary_to_fields
from app.services.session_service import _to_action_model


def test_summary_fields_include_break_stats() -> None:
    summary = SessionSummaryFields(
        total_duration_s=100.0, descent_duration_s=50.0, lift_duration_s=20.0,
        descent_distance_m=500.0, lift_distance_m=300.0, descent_vertical_m=80.0, lift_vertical_m=90.0,
        max_speed_mps=9.0, avg_descent_speed_mps=7.0, peak_altitude_m=1200.0,
        center_lat=49.4, center_long=-123.0, altitude_offset_m=0.0,
        break_count=2, break_duration_s=310.0,
    )
    fields = _summary_to_fields(summary)
    assert fields["break_count"] == 2
    assert fields["break_duration_s"] == 310.0


def test_action_model_carries_lift_name() -> None:
    now = datetime(2026, 2, 1, 10, 0, tzinfo=UTC)
    record = ActionRecord(
        action_type="lift", sequence_index=1, started_at=now, ended_at=now, duration_s=0.0,
        distance_m=0.0, avg_speed_mps=0.0, max_speed_mps=0.0, min_speed_mps=None, vertical_m=None,
        min_altitude_m=None, max_altitude_m=None, min_lat=None, max_lat=None, min_long=None,
        max_long=None, top_speed_lat=None, top_speed_long=None, top_speed_alt_m=None,
        time_of_day=None, external_track_id="osm:way:1", source="live_analyzer", lift_name="Peak Chair",
    )
    model = _to_action_model(record)
    assert model.lift_name == "Peak Chair"
    assert model.external_track_id == "osm:way:1"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tests/unit/test_session_service_mappers.py -q`
Expected: `KeyError: 'break_count'` and `TypeError ... unexpected keyword argument 'lift_name'` (or `AttributeError`).

- [ ] **Step 3: Migration and models**

```python
# backend/alembic/versions/0015_analyzer_output_fields.py
"""analyzer output fields

Revision ID: 0015_analyzer_output_fields
Revises: 0014_session_point_pressure
Create Date: 2026-09-17 12:10:00
"""

from typing import Sequence
from typing import Union

from alembic import op
import sqlalchemy as sa

revision: str = "0015_analyzer_output_fields"
down_revision: Union[str, None] = "0014_session_point_pressure"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("resort_lifts", sa.Column("osm_aerialway", sa.Text(), nullable=True))
    op.add_column("ride_session_actions", sa.Column("lift_name", sa.Text(), nullable=True))
    op.add_column(
        "ride_sessions",
        sa.Column("break_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
    )
    op.add_column(
        "ride_sessions",
        sa.Column("break_duration_s", sa.Numeric(10, 3), nullable=False, server_default=sa.text("0")),
    )


def downgrade() -> None:
    op.drop_column("ride_sessions", "break_duration_s")
    op.drop_column("ride_sessions", "break_count")
    op.drop_column("ride_session_actions", "lift_name")
    op.drop_column("resort_lifts", "osm_aerialway")
```

Model columns (match each file's existing import set; add `Integer` to `ride_session.py` imports if absent):

```python
# resort_lift.py, after lift_type
    osm_aerialway: Mapped[str | None] = mapped_column(Text, nullable=True)

# ride_session_action.py, after external_track_id
    lift_name: Mapped[str | None] = mapped_column(Text, nullable=True)

# ride_session.py, after total_duration_s
    break_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        server_default=text("0"),
    )
    break_duration_s: Mapped[float] = mapped_column(
        Numeric(10, 3, asdecimal=False),
        nullable=False,
        server_default=text("0"),
    )
```

- [ ] **Step 4: Schema and mappers**

`SessionSummary` (`backend/app/schemas/session.py`), after `total_duration_s: float`:

```python
    break_count: int
    break_duration_s: float
```

`_summary_to_fields`: add `"break_count": summary.break_count,` and `"break_duration_s": summary.break_duration_s,` after `"altitude_offset_m"`. Its return annotation becomes `dict[str, float | int | None]`. `_to_action_model`: add `lift_name=action.lift_name,` after `source=action.source,` (read the function's tail first; keep every existing field).

- [ ] **Step 5: QA test**

Append to `backend/tests/qa/test_sessions_analyze_override_qa.py`, using its `_create_completed_session` helper:

```python
def test_session_detail_reports_break_stats(client, create_resort, register_user) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Break Stats Resort")
    session_id = _create_completed_session(client, headers, resort)

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers)
    assert detail.status_code == 200
    session = detail.json()["session"]
    assert session["break_count"] == 0
    assert session["break_duration_s"] == 0.0
```

- [ ] **Step 6: Migrate, run, gates, commit**

```bash
alembic upgrade head
python -m pytest tests/unit/test_session_service_mappers.py tests/qa/test_sessions_analyze_override_qa.py tests/unit/repositories/test_ride_session_repository_analysis.py -q
ruff check alembic/versions/0015_analyzer_output_fields.py app/models app/schemas/session.py app/services/session_service.py tests/unit/test_session_service_mappers.py tests/qa/test_sessions_analyze_override_qa.py
ruff format --check <same>
mypy app/models app/schemas/session.py app/services/session_service.py
git add <same paths>
git commit -m "feat(backend): persist break stats, lift names, and OSM lift types"
```

---

### Task 3: Feed the lift catalog into analysis

**Files:**
- Modify: `backend/app/services/session_service.py` (constructor, `_run_analysis`, new helpers), `backend/app/core/dependencies/resorts.py` (`get_resort_lift_repository`), `backend/app/core/dependencies/sessions.py`
- Test: `backend/tests/unit/test_session_service_lifts.py` (new), `backend/tests/qa/test_sessions_lift_catalog_qa.py` (new)

**Interfaces:**
- Produces: `SessionService(..., resort_lift_repository: ResortLiftRepositoryProtocol | None = None)`; module function `_to_analyzer_lift(model: ResortLift) -> analysis.ResortLift | None`; `get_resort_lift_repository(db) -> ResortLiftRepository`.

- [ ] **Step 1: Write the failing unit test**

```python
# backend/tests/unit/test_session_service_lifts.py
from datetime import UTC
from datetime import datetime
import json
from unittest.mock import MagicMock
import uuid

from app.models.resort_lift import ResortLift as ResortLiftModel
from app.models.ride_session import RideSession
from app.services.analysis import AnalysisResult
from app.services.analysis import SessionSummaryFields
from app.services.session_service import SessionService
from app.services.session_service import _to_analyzer_lift


def _summary() -> SessionSummaryFields:
    return SessionSummaryFields(
        total_duration_s=0.0, descent_duration_s=0.0, lift_duration_s=0.0, descent_distance_m=0.0,
        lift_distance_m=0.0, descent_vertical_m=0.0, lift_vertical_m=0.0, max_speed_mps=None,
        avg_descent_speed_mps=None, peak_altitude_m=None, center_lat=None, center_long=None,
        altitude_offset_m=0.0,
    )


def _lift_model(polyline: str | None) -> ResortLiftModel:
    return ResortLiftModel(
        resort_id=uuid.uuid4(), name="Peak Chair", lift_type="chair", osm_aerialway="chair_lift",
        polyline=polyline, external_track_id="osm:way:9",
    )


def test_analyzer_lift_is_built_from_json_polyline() -> None:
    lift = _to_analyzer_lift(_lift_model(json.dumps([[49.4, -123.0], [49.41, -123.0]])))
    assert lift is not None
    assert lift.name == "Peak Chair"
    assert lift.osm_aerialway == "chair_lift"
    assert lift.external_track_id == "osm:way:9"
    assert lift.polyline == ((49.4, -123.0), (49.41, -123.0))


def test_unusable_polylines_are_skipped() -> None:
    assert _to_analyzer_lift(_lift_model(None)) is None
    assert _to_analyzer_lift(_lift_model("not json")) is None
    assert _to_analyzer_lift(_lift_model(json.dumps([[49.4, -123.0]]))) is None


def test_run_analysis_passes_catalog_lifts_to_the_analyzer() -> None:
    analyzer = MagicMock()
    analyzer.analyze.return_value = AnalysisResult(summary=_summary(), actions=[], overrides=[], analyzer_version="v")
    lift_repo = MagicMock()
    lift_repo.list_by_resort.return_value = [_lift_model(json.dumps([[49.4, -123.0], [49.41, -123.0]]))]
    points_repo = MagicMock()
    points_repo.list_by_session.return_value = []
    sessions_repo = MagicMock()
    service = SessionService(
        ride_session_repository=sessions_repo,
        resort_repository=MagicMock(),
        session_point_repository=points_repo,
        session_override_repository=MagicMock(),
        session_analyzer=analyzer,
        resort_lift_repository=lift_repo,
    )
    resort_id = uuid.uuid4()
    ride_session = RideSession(
        id=uuid.uuid4(), user_id=uuid.uuid4(), resort_id=resort_id,
        started_at=datetime(2026, 2, 1, 10, 0, tzinfo=UTC), ended_at=datetime(2026, 2, 1, 11, 0, tzinfo=UTC),
        source="live_recording", sport="snowboard",
    )

    service._run_analysis(ride_session, include_overrides=False)

    lift_repo.list_by_resort.assert_called_once_with(resort_id)
    analyzer_input = analyzer.analyze.call_args.args[0]
    assert [lift.name for lift in analyzer_input.resort_lifts] == ["Peak Chair"]


def test_run_analysis_without_resort_passes_no_lifts() -> None:
    analyzer = MagicMock()
    analyzer.analyze.return_value = AnalysisResult(summary=_summary(), actions=[], overrides=[], analyzer_version="v")
    lift_repo = MagicMock()
    points_repo = MagicMock()
    points_repo.list_by_session.return_value = []
    service = SessionService(
        ride_session_repository=MagicMock(), resort_repository=MagicMock(), session_point_repository=points_repo,
        session_override_repository=MagicMock(), session_analyzer=analyzer, resort_lift_repository=lift_repo,
    )
    ride_session = RideSession(
        id=uuid.uuid4(), user_id=uuid.uuid4(), resort_id=None,
        started_at=datetime(2026, 2, 1, 10, 0, tzinfo=UTC), ended_at=None, source="live_recording", sport="snowboard",
    )
    service._run_analysis(ride_session, include_overrides=False)
    lift_repo.list_by_resort.assert_not_called()
    assert analyzer.analyze.call_args.args[0].resort_lifts == ()
```

If `RideSession(...)` needs other non-null constructor fields in this repo's model (check `backend/app/models/ride_session.py`), add them with plain values; the test only needs `id`, `resort_id`, `started_at`, `ended_at`, `source`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tests/unit/test_session_service_lifts.py -q`
Expected: `ImportError: cannot import name '_to_analyzer_lift'`.

- [ ] **Step 3: Implement**

In `backend/app/services/session_service.py`: add imports `import json`, `from app.models.resort_lift import ResortLift as ResortLiftModel`, `from app.repositories.protocols import ResortLiftRepositoryProtocol`, `from app.services.session_analyzer import ResortLift`. Constructor: add the keyword parameter `resort_lift_repository: ResortLiftRepositoryProtocol | None = None` last and store it as `self._resort_lift_repository`. In `_run_analysis`, before building `analyzer_input`:

```python
        resort_lifts = self._load_resort_lifts(ride_session.resort_id)
```
and pass `resort_lifts=resort_lifts,` to `AnalyzerInput(...)`. Add:

```python
    def _load_resort_lifts(self, resort_id: uuid.UUID | None) -> tuple[ResortLift, ...]:
        if resort_id is None or self._resort_lift_repository is None:
            return ()
        lifts = []
        for model in self._resort_lift_repository.list_by_resort(resort_id):
            lift = _to_analyzer_lift(model)
            if lift is not None:
                lifts.append(lift)
        return tuple(lifts)
```
and the module-level helper:

```python
def _to_analyzer_lift(model: ResortLiftModel) -> ResortLift | None:
    if not model.polyline:
        return None
    try:
        raw = json.loads(model.polyline)
    except ValueError:
        logger.warning("Ignoring lift %s: polyline is not JSON", model.id)
        return None
    if not isinstance(raw, list):
        return None
    vertices: list[tuple[float, float]] = []
    for item in raw:
        if isinstance(item, (list, tuple)) and len(item) == 2:
            vertices.append((float(item[0]), float(item[1])))
    if len(vertices) < 2:
        return None
    return ResortLift(
        name=model.name,
        polyline=tuple(vertices),
        lift_type=model.lift_type,
        osm_aerialway=model.osm_aerialway,
        external_track_id=model.external_track_id,
    )
```

Dependencies: in `resorts.py` add

```python
def get_resort_lift_repository(db: Session = Depends(get_db)) -> ResortLiftRepository:
    return ResortLiftRepository(db)
```
(import `ResortLiftRepository`), and in `sessions.py` add a `resort_lift_repository: ResortLiftRepository = Depends(get_resort_lift_repository)` parameter to `get_session_service` and pass `resort_lift_repository=resort_lift_repository`.

- [ ] **Step 4: QA test through the API**

```python
# backend/tests/qa/test_sessions_lift_catalog_qa.py
import json
import uuid

from app.models.resort_lift import ResortLift
from app.models.ride_session_action import RideSessionAction

DEG_LAT_PER_M = 1.0 / 110_540.0


def _climb_points(count: int = 240) -> list[dict]:
    return [
        {
            "t_offset_ms": i * 1000,
            "latitude": 49.4 + 4.0 * i * DEG_LAT_PER_M,
            "longitude": -123.0,
            "altitude_m": 700.0 + 1.5 * i,
            "speed_mps": 4.0,
            "accuracy_m": 3.0,
        }
        for i in range(count)
    ]


def test_completed_session_names_the_lift_it_rode(client, create_resort, register_user, db) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Catalog Resort")
    db.add(
        ResortLift(
            resort_id=resort.id, name="Test Chair", lift_type="chair", osm_aerialway="chair_lift",
            polyline=json.dumps([[49.4, -123.0], [49.4 + 1000 * DEG_LAT_PER_M, -123.0]]),
            external_track_id="osm:way:1",
        )
    )
    db.commit()

    created = client.post("/v1/sessions", json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"}, headers=headers)
    session_id = created.json()["id"]
    assert client.post(f"/v1/sessions/{session_id}/points:batch", json={"points": _climb_points()}, headers=headers).status_code == 200
    assert client.post(f"/v1/sessions/{session_id}/complete", json={"ended_at": "2026-01-01T00:04:00Z"}, headers=headers).status_code == 200

    detail = client.get(f"/v1/sessions/{session_id}", headers=headers).json()
    assert [a["action_type"] for a in detail["actions"]] == ["lift"]
    assert "lift_name" not in detail["actions"][0]
    stored = db.query(RideSessionAction).filter(RideSessionAction.session_id == uuid.UUID(session_id)).all()
    assert [a.lift_name for a in stored] == ["Test Chair"]
    assert stored[0].external_track_id == "osm:way:1"


def test_session_without_catalog_still_analyzes(client, create_resort, register_user) -> None:
    user = register_user()
    headers = {"Authorization": f"Bearer {user['access_token']}"}
    resort = create_resort(name="Empty Catalog Resort")
    created = client.post("/v1/sessions", json={"resort_id": str(resort.id), "started_at": "2026-01-01T00:00:00Z"}, headers=headers)
    session_id = created.json()["id"]
    assert client.post(f"/v1/sessions/{session_id}/points:batch", json={"points": _climb_points()}, headers=headers).status_code == 200
    assert client.post(f"/v1/sessions/{session_id}/complete", json={"ended_at": "2026-01-01T00:04:00Z"}, headers=headers).status_code == 200
    detail = client.get(f"/v1/sessions/{session_id}", headers=headers).json()
    assert [a["action_type"] for a in detail["actions"]] == ["lift"]
```

Add `"resort_lifts"` to `TABLES_TO_TRUNCATE` in `backend/tests/qa/conftest.py` if it is not already listed (it must be truncated before `resorts`, which `CASCADE` handles).

- [ ] **Step 5: Run, gates, commit**

```bash
python -m pytest tests/unit/test_session_service_lifts.py tests/unit/test_session_service.py tests/qa/test_sessions_lift_catalog_qa.py -q
ruff check app/services/session_service.py app/core/dependencies tests/unit/test_session_service_lifts.py tests/qa/test_sessions_lift_catalog_qa.py tests/qa/conftest.py
ruff format --check <same>
mypy app/services/session_service.py app/core/dependencies
git add <same paths>
git commit -m "feat(backend): analyze sessions against the resort lift catalog"
```

---

### Task 4: Overpass lift import

**Files:**
- Create: `backend/app/services/osm_lift_catalog_service.py`, `backend/app/scripts/import_resort_lifts.py`
- Modify: `backend/app/core/config.py`, `docker-compose.yml`, `.env.example`, `backend/app/repositories/protocols.py`, `backend/app/repositories/resort_lift_repository.py`, `backend/app/repositories/resort_repository.py`, `README.md`
- Test: `backend/tests/unit/test_osm_lift_catalog_service.py` (new), `backend/tests/unit/repositories/test_resort_lift_repository.py` (append), `backend/tests/unit/test_config.py` (append)

**Interfaces:**
- Consumes: `OsmLift`, `map_overpass_ways` from `app/services/osm_lift_mapping.py` (plan 1).
- Produces: settings `overpass_base_url` (default `https://overpass-api.de/api/interpreter`), `overpass_timeout_seconds` (`PositiveInt`, 60); `ResortLiftRepositoryProtocol.upsert_by_external_track_id(resort_id, rows: Sequence[ResortLift]) -> int`; `ResortRepositoryProtocol.get_by_name(name: str) -> Resort | None` (case-insensitive exact match); `OsmLiftCatalogService(base_url, timeout_seconds, client=None, sleep=time.sleep)` with `fetch_lifts(latitude, longitude, radius_m) -> list[OsmLift]` and `import_for_resort(resort, repository, radius_m) -> int`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/unit/test_osm_lift_catalog_service.py
import json
from pathlib import Path

import httpx
import pytest

from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.osm_lift_catalog_service import OsmLiftCatalogService

_FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "osm" / "overpass_grouse.json"


def _service(handler) -> OsmLiftCatalogService:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return OsmLiftCatalogService(base_url="https://overpass.test/api/interpreter", timeout_seconds=5, client=client, sleep=lambda _: None)


def test_fetch_lifts_posts_an_around_query_and_maps_the_payload() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = request.content.decode()
        seen["agent"] = request.headers.get("user-agent", "")
        return httpx.Response(200, content=_FIXTURE.read_bytes())

    lifts = _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)
    assert seen["url"] == "https://overpass.test/api/interpreter"
    assert "around%3A6000%2C49.38%2C-123.082" in seen["body"] or "around:6000,49.38,-123.082" in seen["body"]
    assert seen["agent"].startswith("FallLine/1.0")
    assert {lift.name for lift in lifts} >= {"Screaming Eagle Chair", "Red Skyride"}
    assert not any("Zip Line" in lift.name for lift in lifts)


def test_http_failure_becomes_service_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(504)

    with pytest.raises(ServiceUnavailableError):
        _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)


def test_invalid_json_becomes_validation_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>rate limited</html>")

    with pytest.raises(ValidationError):
        _service(handler).fetch_lifts(latitude=49.38, longitude=-123.082, radius_m=6000)


def test_import_for_resort_requires_coordinates() -> None:
    from unittest.mock import MagicMock

    resort = MagicMock(latitude=None, longitude=None)
    with pytest.raises(ValidationError):
        _service(lambda request: httpx.Response(200, json={"elements": []})).import_for_resort(resort, MagicMock(), radius_m=6000)


def test_import_for_resort_upserts_mapped_rows() -> None:
    from unittest.mock import MagicMock
    import uuid

    resort = MagicMock(id=uuid.uuid4(), latitude=49.38, longitude=-123.082)
    repository = MagicMock()
    repository.upsert_by_external_track_id.return_value = 8
    service = _service(lambda request: httpx.Response(200, content=_FIXTURE.read_bytes()))

    count = service.import_for_resort(resort, repository, radius_m=6000)

    assert count == 8
    rows = repository.upsert_by_external_track_id.call_args.args[1]
    assert all(row.resort_id == resort.id for row in rows)
    assert {row.osm_aerialway for row in rows} >= {"chair_lift", "cable_car", "magic_carpet"}
    first = json.loads(next(row.polyline for row in rows if row.name == "Peak Chair"))
    assert len(first) >= 2 and len(first[0]) == 2
    repository.commit.assert_called_once()
```

Append to `backend/tests/unit/repositories/test_resort_lift_repository.py`:

```python
def test_upsert_by_external_track_id_inserts_then_updates(
    db: Session, create_resort: Callable[..., Resort]
) -> None:
    resort = create_resort()
    repo = ResortLiftRepository(db)
    first = [ResortLift(resort_id=resort.id, name="Old Name", lift_type="chair", polyline="[[1,2],[3,4]]", external_track_id="osm:way:1")]
    assert repo.upsert_by_external_track_id(resort.id, first) == 1
    repo.commit()
    second = [
        ResortLift(resort_id=resort.id, name="New Name", lift_type="gondola", osm_aerialway="gondola", polyline="[[1,2],[3,5]]", external_track_id="osm:way:1"),
        ResortLift(resort_id=resort.id, name="Other", lift_type="surface", polyline="[[0,0],[0,1]]", external_track_id="osm:way:2"),
    ]
    assert repo.upsert_by_external_track_id(resort.id, second) == 2
    repo.commit()
    lifts = {lift.external_track_id: lift for lift in repo.list_by_resort(resort.id)}
    assert set(lifts) == {"osm:way:1", "osm:way:2"}
    assert lifts["osm:way:1"].name == "New Name"
    assert lifts["osm:way:1"].lift_type == "gondola"
    assert lifts["osm:way:1"].osm_aerialway == "gondola"
```

Append to `backend/tests/unit/test_config.py` (follow the file's existing pattern for constructing settings):

```python
def test_overpass_defaults() -> None:
    settings = AppSettings(jwt_secret_key="x" * 32)
    assert settings.overpass_base_url == "https://overpass-api.de/api/interpreter"
    assert settings.overpass_timeout_seconds == 60
```

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tests/unit/test_osm_lift_catalog_service.py tests/unit/test_config.py -q`
Expected: `ModuleNotFoundError` for the service and `AttributeError` for the settings.

- [ ] **Step 3: Settings, compose, env example**

`AppSettings`, after `resort_sync_interval_days`:

```python
    overpass_base_url: str = "https://overpass-api.de/api/interpreter"
    overpass_timeout_seconds: PositiveInt = 60
```
with a validator like `_validate_ski_api_base_url` that strips a trailing slash and rejects empty. `docker-compose.yml` backend environment: `OVERPASS_BASE_URL: ${OVERPASS_BASE_URL:-https://overpass-api.de/api/interpreter}` and `OVERPASS_TIMEOUT_SECONDS: ${OVERPASS_TIMEOUT_SECONDS:-60}`. `.env.example`, after the Ski API block:

```
# OpenStreetMap Overpass endpoint used by `python -m app.scripts.import_resort_lifts`.
OVERPASS_BASE_URL=https://overpass-api.de/api/interpreter
OVERPASS_TIMEOUT_SECONDS=60
```

- [ ] **Step 4: Repository methods**

Protocol additions:

```python
# ResortRepositoryProtocol
    def get_by_name(self, name: str) -> Resort | None: ...

# ResortLiftRepositoryProtocol
    def upsert_by_external_track_id(self, resort_id: uuid.UUID, rows: Sequence[ResortLift]) -> int: ...

    def commit(self) -> None: ...
```

`ResortRepository.get_by_name`:

```python
    def get_by_name(self, name: str) -> Resort | None:
        stmt = select(Resort).where(func.lower(Resort.name) == name.strip().lower())
        return self._db.scalars(stmt).first()
```
(import `func` from sqlalchemy). `ResortLiftRepository`:

```python
    def upsert_by_external_track_id(self, resort_id: uuid.UUID, rows: Sequence[ResortLift]) -> int:
        count = 0
        for row in rows:
            existing = self._db.scalars(
                select(ResortLift).where(
                    ResortLift.resort_id == resort_id,
                    ResortLift.external_track_id == row.external_track_id,
                )
            ).first()
            if existing is None:
                row.resort_id = resort_id
                self._db.add(row)
            else:
                existing.name = row.name
                existing.lift_type = row.lift_type
                existing.osm_aerialway = row.osm_aerialway
                existing.polyline = row.polyline
                existing.base_altitude_m = row.base_altitude_m
                existing.top_altitude_m = row.top_altitude_m
            count += 1
        return count
```
`commit` comes from `SqlAlchemyRepository`; confirm the base class exposes it (the other repositories rely on it).

- [ ] **Step 5: The service**

```python
"""Fetch resort lift lines from OpenStreetMap through the Overpass API (spec section 3)."""

from __future__ import annotations

from collections.abc import Callable
import json
import logging
import time
import uuid

import httpx

from app.models.resort import Resort
from app.models.resort_lift import ResortLift
from app.repositories.protocols import ResortLiftRepositoryProtocol
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError
from app.services.osm_lift_mapping import OsmLift
from app.services.osm_lift_mapping import map_overpass_ways

logger = logging.getLogger(__name__)

_USER_AGENT = "FallLine/1.0 (+local)"
_PACE_SECONDS = 1.0


class OsmLiftCatalogService:
    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: int,
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._base_url = base_url
        self._timeout_seconds = timeout_seconds
        self._client = client
        self._sleep = sleep

    def fetch_lifts(self, *, latitude: float, longitude: float, radius_m: int) -> list[OsmLift]:
        query = (
            f"[out:json][timeout:{self._timeout_seconds}];"
            f'way["aerialway"](around:{int(radius_m)},{latitude},{longitude});'
            "out geom;"
        )
        try:
            if self._client is not None:
                response = self._client.post(self._base_url, data={"data": query}, headers={"User-Agent": _USER_AGENT})
            else:
                with httpx.Client(timeout=float(self._timeout_seconds)) as client:
                    response = client.post(self._base_url, data={"data": query}, headers={"User-Agent": _USER_AGENT})
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPError as exc:
            raise ServiceUnavailableError("Overpass API unavailable.") from exc
        except ValueError as exc:
            raise ValidationError("Overpass API returned invalid JSON.") from exc
        finally:
            self._sleep(_PACE_SECONDS)
        if not isinstance(payload, dict):
            raise ValidationError("Overpass API returned an unexpected payload.")
        lifts = map_overpass_ways(payload)
        logger.info("Overpass returned %d usable lifts around %.4f, %.4f", len(lifts), latitude, longitude)
        return lifts

    def import_for_resort(
        self, resort: Resort, repository: ResortLiftRepositoryProtocol, *, radius_m: int
    ) -> int:
        if resort.latitude is None or resort.longitude is None:
            raise ValidationError("Resort has no coordinates; cannot import lifts.")
        lifts = self.fetch_lifts(latitude=float(resort.latitude), longitude=float(resort.longitude), radius_m=radius_m)
        rows = [
            ResortLift(
                resort_id=resort.id,
                name=lift.name,
                lift_type=lift.lift_type,
                osm_aerialway=lift.osm_aerialway,
                polyline=json.dumps([[lat, lon] for lat, lon in lift.polyline]),
                base_altitude_m=lift.base_altitude_m,
                top_altitude_m=lift.top_altitude_m,
                external_track_id=lift.external_track_id,
            )
            for lift in lifts
        ]
        count = repository.upsert_by_external_track_id(resort.id, rows)
        repository.commit()
        return count
```

Note: `resort.id` on a `MagicMock` resort in the unit test is a `uuid` attribute the test sets; the `uuid` import above is only needed if you annotate; drop it if ruff flags it unused.

- [ ] **Step 6: The script**

```python
# backend/app/scripts/import_resort_lifts.py
"""Fill resort_lifts from OpenStreetMap for one resort or for a user's favourites.

Usage (from backend/):
    python -m app.scripts.import_resort_lifts --resort "Grouse Mountain" [--radius-m 6000]
    python -m app.scripts.import_resort_lifts --all-favourites --user-email you@example.com
"""

from __future__ import annotations

from argparse import ArgumentParser
import uuid

from app.core.config import get_settings
from app.core.database import get_session_local
from app.models.resort import Resort
from app.repositories.favorite_resort_repository import FavoriteResortRepository
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.user_repository import UserRepository
from app.services.exceptions import ServiceError
from app.services.osm_lift_catalog_service import OsmLiftCatalogService


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="Import lift lines from OpenStreetMap into resort_lifts.")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--resort", help="Resort name (case-insensitive) or resort id.")
    target.add_argument("--all-favourites", action="store_true", help="Every favourite resort of --user-email.")
    parser.add_argument("--user-email", help="Required with --all-favourites.")
    parser.add_argument("--radius-m", type=int, default=6000, help="Search radius around the resort centre.")
    return parser


def main() -> None:
    args = build_argument_parser().parse_args()
    if args.all_favourites and not args.user_email:
        raise SystemExit("--all-favourites requires --user-email")
    settings = get_settings()
    db = get_session_local()()
    try:
        resorts_repo = ResortRepository(db)
        lifts_repo = ResortLiftRepository(db)
        targets: list[Resort] = []
        if args.resort:
            resort = None
            try:
                resort = resorts_repo.get_by_id(uuid.UUID(args.resort))
            except ValueError:
                resort = resorts_repo.get_by_name(args.resort)
            if resort is None:
                raise SystemExit(f"Resort not found: {args.resort}")
            targets.append(resort)
        else:
            user = UserRepository(db).get_by_email(args.user_email)
            if user is None:
                raise SystemExit(f"User not found: {args.user_email}")
            targets.extend(FavoriteResortRepository(db).list_by_user_id(user.id))
        service = OsmLiftCatalogService(
            base_url=settings.overpass_base_url, timeout_seconds=settings.overpass_timeout_seconds
        )
        for resort in targets:
            try:
                count = service.import_for_resort(resort, lifts_repo, radius_m=args.radius_m)
            except ServiceError as exc:
                db.rollback()
                print(f"- {resort.name}: failed ({exc})")
                continue
            print(f"- {resort.name}: {count} lifts upserted")
    finally:
        db.close()


if __name__ == "__main__":
    main()
```

Check the real module and class names for the user and favourite repositories (`app/repositories/`) and adjust the imports; `FavoriteResortRepositoryProtocol.list_by_user_id` and `UserRepositoryProtocol.get_by_email` exist per `protocols.py`.

- [ ] **Step 7: README**

Add after the resort import command in the backend section of `README.md`:

```markdown
### Lift catalog

Lift lines come from OpenStreetMap through the public Overpass API and are
needed for lift naming and the best run/lift detection. After
`python -m app.scripts.import_resorts`, import the lifts for the resorts you
ride (one request per resort, paced at one per second):

```bash
python -m app.scripts.import_resort_lifts --resort "Grouse Mountain"
python -m app.scripts.import_resort_lifts --resort "Cypress Mountain"
python -m app.scripts.import_resort_lifts --resort "Mount Seymour"
# or everything you have favourited:
python -m app.scripts.import_resort_lifts --all-favourites --user-email you@example.com
```

Re-running updates existing rows in place (matched by OSM way id).
```

- [ ] **Step 8: Run, gates, commit**

```bash
python -m pytest tests/unit/test_osm_lift_catalog_service.py tests/unit/test_config.py tests/unit/repositories/test_resort_lift_repository.py -q
ruff check app/services/osm_lift_catalog_service.py app/scripts/import_resort_lifts.py app/core/config.py app/repositories tests/unit/test_osm_lift_catalog_service.py tests/unit/repositories/test_resort_lift_repository.py tests/unit/test_config.py
ruff format --check <same>
mypy app/services/osm_lift_catalog_service.py app/scripts/import_resort_lifts.py app/core/config.py app/repositories
git add <same paths> docker-compose.yml .env.example README.md
git commit -m "feat(backend): import resort lift lines from OpenStreetMap"
```

---

### Task 5: Re-analysis, version bump, contract fixtures, docs

**Files:**
- Create: `backend/app/scripts/reanalyze_sessions.py`, `backend/app/scripts/sync_contract_fixtures.py`, `backend/tests/fixtures/contracts/session_point_batch.json`, `backend/tests/fixtures/contracts/session_detail.json`, `mobile/test/fixtures/contracts/` copies, `backend/tests/unit/test_contract_fixtures.py`, `backend/tests/unit/test_reanalyze_sessions.py`
- Modify: `backend/app/core/config.py` (`session_analyzer_version` default), `.env.example` (if it lists `SESSION_ANALYZER_VERSION`), `backend/app/repositories/protocols.py`, `backend/app/repositories/ride_session_repository.py` (`list_needing_reanalysis`), `backend/app/services/session_service.py` (`reanalyze_session`), `docs/ARCHITECTURE_SUMMARY.md`, `backend/tests/TEST_PLAN.md`, `README.md`

**Interfaces:**
- Produces: `RideSessionRepositoryProtocol.list_needing_reanalysis(current_version: str, *, limit: int) -> list[RideSession]` (status COMPLETED, `processed_by_version` null or different, oldest first); `SessionService.reanalyze_session(ride_session) -> None`; analyzer version `analyzer@2026.09-hmm`.

- [ ] **Step 1: Contract fixtures and their tests (write the tests first)**

```python
# backend/tests/unit/test_contract_fixtures.py
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
```

`session_point_batch.json`:

```json
{
  "points": [
    {"t_offset_ms": 0, "latitude": 49.38, "longitude": -123.08, "accuracy_m": 3.0, "elapsed_realtime_ns": 100000000, "recorded_at": "2026-01-18T20:05:13Z", "altitude_m": 1091.5, "vertical_accuracy_m": 4.7, "speed_mps": 1.19, "speed_accuracy_mps": 0.4, "heading_deg": 36.7, "bearing_accuracy_deg": 12.0, "provider": "fused", "is_mocked": false, "pressure_hpa": 898.7},
    {"t_offset_ms": 1000, "latitude": 49.3801, "longitude": -123.08, "accuracy_m": 3.2, "elapsed_realtime_ns": 1100000000, "recorded_at": "2026-01-18T20:05:14Z", "altitude_m": 1091.0, "vertical_accuracy_m": 4.5, "speed_mps": 1.0, "speed_accuracy_mps": 0.4, "heading_deg": 39.4, "bearing_accuracy_deg": 12.0, "provider": "fused", "is_mocked": false}
  ]
}
```

`session_detail.json`: build it from a real response. Run the QA helper flow once against the test database (create a user, a resort, post the 200-point downhill batch from `tests/qa/test_sessions_analyze_override_qa.py`, complete, GET the detail), then edit the captured JSON so that `session.break_count` is `1`, `session.break_duration_s` is `240.0`, and `actions` contains exactly one `run` followed by one `lift` (copy the run object, change `action_type` to `lift`, `sequence_index` to 1, give it a distinct `id`). Keep every field the API returned; the fixture must validate against `SessionDetailResponse` unchanged. Do not include real GPS coordinates other than the synthetic ones from the QA helper.

`sync_contract_fixtures.py`:

```python
"""Copy the shared contract fixtures to the mobile test tree. Run from backend/."""

from pathlib import Path
import shutil

_BACKEND = Path(__file__).resolve().parents[2]
SOURCE = _BACKEND / "tests" / "fixtures" / "contracts"
TARGET = _BACKEND.parent / "mobile" / "test" / "fixtures" / "contracts"


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for path in sorted(SOURCE.glob("*.json")):
        shutil.copyfile(path, TARGET / path.name)
        print(f"copied {path.name}")


if __name__ == "__main__":
    main()
```

Run `python -m app.scripts.sync_contract_fixtures`, then `python -m pytest tests/unit/test_contract_fixtures.py -q` (expected: 3 passed).

- [ ] **Step 2: Re-analysis repository method, service method, script, tests**

Protocol and repository:

```python
# RideSessionRepositoryProtocol
    def list_needing_reanalysis(self, current_version: str, *, limit: int) -> list[RideSession]: ...
```
```python
    def list_needing_reanalysis(self, current_version: str, *, limit: int) -> list[RideSession]:
        stmt = (
            select(RideSession)
            .where(
                RideSession.status == RideSessionStatus.COMPLETED,
                or_(RideSession.processed_by_version.is_(None), RideSession.processed_by_version != current_version),
            )
            .order_by(RideSession.created_at.asc())
            .limit(limit)
        )
        return list(self._db.scalars(stmt).all())
```
(import `or_`; confirm the status enum name and import in the model.)

Service:

```python
    def reanalyze_session(self, ride_session: RideSession) -> None:
        """Re-run analysis for a stored session without an ownership check (operations only)."""
        self._run_analysis(ride_session, include_overrides=True)
        self._ride_session_repository.commit()
```

Script:

```python
# backend/app/scripts/reanalyze_sessions.py
"""Re-run the analyzer over stored sessions processed by an older analyzer version.

Usage (from backend/):
    python -m app.scripts.reanalyze_sessions [--batch-size 50] [--dry-run]
"""

from __future__ import annotations

from argparse import ArgumentParser

from app.core.config import get_settings
from app.core.database import get_session_local
from app.core.dependencies.sessions import get_session_analyzer
from app.repositories.resort_lift_repository import ResortLiftRepository
from app.repositories.resort_repository import ResortRepository
from app.repositories.ride_session_repository import RideSessionRepository
from app.repositories.session_override_repository import SessionOverrideRepository
from app.repositories.session_point_repository import SessionPointRepository
from app.services.exceptions import ServiceError
from app.services.session_service import SessionService


def build_argument_parser() -> ArgumentParser:
    parser = ArgumentParser(description="Re-analyze sessions not processed by the current analyzer version.")
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--dry-run", action="store_true", help="Count and list sessions without changing them.")
    return parser


def main() -> None:
    args = build_argument_parser().parse_args()
    version = get_settings().session_analyzer_version
    db = get_session_local()()
    try:
        sessions_repo = RideSessionRepository(db)
        service = SessionService(
            ride_session_repository=sessions_repo,
            resort_repository=ResortRepository(db),
            session_point_repository=SessionPointRepository(db),
            session_override_repository=SessionOverrideRepository(db),
            session_analyzer=get_session_analyzer(),
            resort_lift_repository=ResortLiftRepository(db),
        )
        done = failed = 0
        while True:
            batch = sessions_repo.list_needing_reanalysis(version, limit=args.batch_size)
            if not batch:
                break
            if args.dry_run:
                for session in batch:
                    print(f"- {session.id} ({session.processed_by_version or 'never'})")
                done += len(batch)
                break
            for session in batch:
                try:
                    service.reanalyze_session(session)
                    done += 1
                except ServiceError as exc:
                    db.rollback()
                    failed += 1
                    print(f"- {session.id}: failed ({exc})")
    finally:
        db.close()
    print(f"{'Would re-analyze' if args.dry_run else 'Re-analyzed'} {done} session(s); failed {failed}; version {version}")


if __name__ == "__main__":
    main()
```

Unit test:

```python
# backend/tests/unit/test_reanalyze_sessions.py
from unittest.mock import MagicMock

from app.services.session_service import SessionService


def test_reanalyze_session_runs_analysis_with_overrides_and_commits() -> None:
    service = SessionService(
        ride_session_repository=MagicMock(), resort_repository=MagicMock(), session_point_repository=MagicMock(),
        session_override_repository=MagicMock(), session_analyzer=MagicMock(),
    )
    service._run_analysis = MagicMock()  # type: ignore[method-assign]
    ride_session = MagicMock()

    service.reanalyze_session(ride_session)

    service._run_analysis.assert_called_once_with(ride_session, include_overrides=True)
    service._ride_session_repository.commit.assert_called_once()
```

Repository test, appended to `tests/unit/repositories/test_ride_session_repository_analysis.py` (use its existing fixtures `db`, `create_ride_session`):

```python
def test_list_needing_reanalysis_skips_current_version(db, create_ride_session) -> None:
    from app.models.ride_session import RideSessionStatus
    from app.repositories.ride_session_repository import RideSessionRepository

    stale = create_ride_session()
    stale.status = RideSessionStatus.COMPLETED
    stale.processed_by_version = "analyzer@1"
    fresh = create_ride_session()
    fresh.status = RideSessionStatus.COMPLETED
    fresh.processed_by_version = "analyzer@2026.09-hmm"
    db.commit()

    found = RideSessionRepository(db).list_needing_reanalysis("analyzer@2026.09-hmm", limit=10)
    assert [s.id for s in found] == [stale.id]
```
(If `RideSessionStatus` lives elsewhere, import it from there; if `create_ride_session` accepts a status keyword, use it instead of setting the attribute.)

- [ ] **Step 3: Version bump and docs**

`AppSettings.session_analyzer_version` default becomes `"analyzer@2026.09-hmm"`; update `.env.example` if it lists the variable. Docs:

- `README.md`, after the lift catalog section: a "Re-analysis" paragraph with `python -m app.scripts.reanalyze_sessions --dry-run` then without `--dry-run`, explaining that sessions keep their old actions until re-analyzed.
- `docs/ARCHITECTURE_SUMMARY.md`: in the backend services description, replace the mention of `session_analyzer.py` with the `app/services/analysis/` package layout (config, signal, lift_matching, hmm, actions, analyzer) and note that `session_analyzer.py` is a shim.
- `backend/tests/TEST_PLAN.md`: add the new QA files (`test_sessions_lift_catalog_qa.py`) and the contract-fixture test to the relevant lists.

- [ ] **Step 4: Full verification, gates, commit**

```bash
export DATABASE_URL="$(grep '^DATABASE_URL=' ../.env | cut -d= -f2- | sed 's#/goofyrider$#/goofyrider_test#')"
alembic upgrade head
python -m pytest -q
ruff check app tests
ruff format --check app tests
mypy
```
Expected: the suite passes (the analyzer corpus gate included). `ruff check app tests` and `mypy` may still show the older, unrelated errors that existed before plan 1; none may be in files this plan touched. Then:

```bash
git add backend/app backend/tests backend/alembic docs/ARCHITECTURE_SUMMARY.md README.md .env.example mobile/test/fixtures/contracts
git commit -m "feat(backend): re-analysis script, new analyzer version, shared contract fixtures"
```
