from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import re
import statistics
import zipfile
import xml.etree.ElementTree as ET

import pytest

_FIXTURE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "slopes"
_FIXTURE_FILENAMES = (
    "cypress_2026-03-21.slopes",
    "grouse_2025-04-13.slopes",
    "grouse_2026-01-18.slopes",
)

_METADATA_DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S %z"
_METRIC_ABS_TOL = 1e-5
_PEAK_ALTITUDE_NOT_GPS_TOL_M = 0.1
_CYPRESS_MEAN_RUN_KMH = 23.1
_CYPRESS_MEAN_RUN_KMH_TOL = 0.1
_OVERRIDE_SEGMENT_PATTERN = re.compile(
    r"^(?P<start>\d+)-(?P<end>\d+):(?P<state>ignore|lift|run)$"
)
_ALLOWED_ACTION_TYPES = {"Run", "Lift"}


@dataclass(frozen=True)
class ParsedAction:
    action_type: str
    distance_m: float
    vertical_m: float
    top_speed_mps: float
    avg_speed_mps: float
    max_alt_m: float


@dataclass(frozen=True)
class ParsedSlopesFixture:
    fixture_name: str
    record_start: datetime
    record_end: datetime
    distance_m: float
    vertical_m: float
    top_speed_mps: float
    peak_altitude_m: float
    conditions: str
    overrides: tuple[str, ...]
    actions: tuple[ParsedAction, ...]
    gps_altitudes_m: tuple[float, ...]

    @property
    def run_actions(self) -> tuple[ParsedAction, ...]:
        return tuple(action for action in self.actions if action.action_type == "Run")


@pytest.fixture(scope="module")
def slopes_fixtures() -> dict[str, ParsedSlopesFixture]:
    return {
        filename: _parse_slopes_fixture(_FIXTURE_DIR / filename)
        for filename in _FIXTURE_FILENAMES
    }


def test_slopes_fixture_session_reconciliation_contract(
    slopes_fixtures: dict[str, ParsedSlopesFixture],
) -> None:
    for fixture in slopes_fixtures.values():
        # Parsed values prove recordStart/recordEnd are datetime strings, not epoch integers.
        assert fixture.record_end > fixture.record_start
        assert fixture.run_actions
        assert {action.action_type for action in fixture.actions} <= _ALLOWED_ACTION_TYPES

        assert fixture.distance_m == pytest.approx(
            sum(action.distance_m for action in fixture.run_actions),
            abs=_METRIC_ABS_TOL,
        )
        assert fixture.vertical_m == pytest.approx(
            sum(action.vertical_m for action in fixture.run_actions),
            abs=_METRIC_ABS_TOL,
        )
        assert fixture.top_speed_mps == pytest.approx(
            max(action.top_speed_mps for action in fixture.run_actions),
            abs=_METRIC_ABS_TOL,
        )

        max_action_altitude_m = max(action.max_alt_m for action in fixture.actions)
        max_gps_altitude_m = max(fixture.gps_altitudes_m)

        assert fixture.peak_altitude_m == pytest.approx(
            max_action_altitude_m,
            abs=_METRIC_ABS_TOL,
        )
        assert (
            abs(fixture.peak_altitude_m - max_gps_altitude_m)
            > _PEAK_ALTITUDE_NOT_GPS_TOL_M
        )


def test_slopes_fixture_override_contract(slopes_fixtures: dict[str, ParsedSlopesFixture]) -> None:
    cypress = slopes_fixtures["cypress_2026-03-21.slopes"]
    grouse_2025 = slopes_fixtures["grouse_2025-04-13.slopes"]
    grouse_2026 = slopes_fixtures["grouse_2026-01-18.slopes"]

    # These assertions pin what is actually in the copied archives.
    assert cypress.overrides == ()
    assert grouse_2025.overrides
    assert grouse_2026.overrides

    for fixture in (grouse_2025, grouse_2026):
        for token in fixture.overrides:
            match = _OVERRIDE_SEGMENT_PATTERN.fullmatch(token)
            assert match is not None
            assert int(match.group("start")) <= int(match.group("end"))


def test_cypress_fixture_mean_run_average_speed_kmh(
    slopes_fixtures: dict[str, ParsedSlopesFixture],
) -> None:
    cypress = slopes_fixtures["cypress_2026-03-21.slopes"]

    mean_run_speed_kmh = statistics.mean(action.avg_speed_mps for action in cypress.run_actions) * 3.6

    assert mean_run_speed_kmh == pytest.approx(
        _CYPRESS_MEAN_RUN_KMH,
        abs=_CYPRESS_MEAN_RUN_KMH_TOL,
    )


def test_slopes_fixture_conditions_casing_contract(
    slopes_fixtures: dict[str, ParsedSlopesFixture],
) -> None:
    # Pin exact casing of all Activity.conditions values in the Step 0 fixtures.
    assert slopes_fixtures["cypress_2026-03-21.slopes"].conditions == "WET"
    assert slopes_fixtures["grouse_2025-04-13.slopes"].conditions == "PACKED"
    assert slopes_fixtures["grouse_2026-01-18.slopes"].conditions == ""


def _parse_slopes_fixture(fixture_path: Path) -> ParsedSlopesFixture:
    with zipfile.ZipFile(fixture_path) as archive:
        metadata_root = ET.fromstring(archive.read("Metadata.xml"))
        actions = _parse_actions(metadata_root)
        gps_altitudes_m = _parse_gps_altitudes_m(archive)

    record_start = datetime.strptime(
        metadata_root.attrib["recordStart"],
        _METADATA_DATETIME_FORMAT,
    )
    record_end = datetime.strptime(
        metadata_root.attrib["recordEnd"],
        _METADATA_DATETIME_FORMAT,
    )

    raw_overrides = metadata_root.attrib.get("overrides", "")
    overrides = tuple(segment for segment in raw_overrides.split(";") if segment)

    return ParsedSlopesFixture(
        fixture_name=fixture_path.name,
        record_start=record_start,
        record_end=record_end,
        distance_m=float(metadata_root.attrib["distance"]),
        vertical_m=float(metadata_root.attrib["vertical"]),
        top_speed_mps=float(metadata_root.attrib["topSpeed"]),
        peak_altitude_m=float(metadata_root.attrib["peakAltitude"]),
        conditions=metadata_root.attrib.get("conditions", ""),
        overrides=overrides,
        actions=actions,
        gps_altitudes_m=gps_altitudes_m,
    )


def _parse_actions(metadata_root: ET.Element) -> tuple[ParsedAction, ...]:
    actions_root = metadata_root.find("actions")
    if actions_root is None:
        raise AssertionError("Metadata.xml is missing <actions>.")

    parsed_actions: list[ParsedAction] = []
    for action in actions_root.findall("Action"):
        parsed_actions.append(
            ParsedAction(
                action_type=action.attrib["type"],
                distance_m=float(action.attrib["distance"]),
                vertical_m=float(action.attrib["vertical"]),
                top_speed_mps=float(action.attrib["topSpeed"]),
                avg_speed_mps=float(action.attrib["avgSpeed"]),
                max_alt_m=float(action.attrib["maxAlt"]),
            )
        )

    return tuple(parsed_actions)


def _parse_gps_altitudes_m(archive: zipfile.ZipFile) -> tuple[float, ...]:
    gps_csv = archive.read("GPS.csv").decode("utf-8-sig")
    rows = csv.reader(gps_csv.splitlines())
    return tuple(float(row[3]) for row in rows if row)
