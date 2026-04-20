from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
from pathlib import Path
from typing import Iterable
from uuid import UUID
import csv
import io
import math
import zipfile
import xml.etree.ElementTree as ET

from sqlalchemy import delete
from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.resort import Resort
from app.models.ride_session import RideSession
from app.models.ride_session import RideSessionStatus
from app.models.session_point import SessionPoint
from app.models.user import User

_GPS_ENTRY_NAME = "GPS.csv"
_METADATA_ENTRY_NAME = "Metadata.xml"
_SLOPES_DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S %z"
_SOURCE_GLOB = "*.slopes"
_MOTION_STATE_BY_OVERRIDE = {
    "ignore": "stopped_idle",
    "lift": "lift_uphill",
    "run": "active_descent",
}
_MOTION_STATE_BY_ACTION_TYPE = {
    "lift": "lift_uphill",
    "run": "active_descent",
}
_PROVIDER_GPS = "gps"
_OVERRIDE_SEGMENT_PRIORITY = 20
_ACTION_SEGMENT_PRIORITY = 10


@dataclass(frozen=True)
class SlopesOverrideSegment:
    start_epoch_s: int
    end_epoch_s: int
    motion_state: str
    priority: int = _OVERRIDE_SEGMENT_PRIORITY


@dataclass(frozen=True)
class ParsedSlopesPoint:
    t_offset_ms: int
    recorded_at: datetime
    latitude: float
    longitude: float
    altitude_m: float | None
    speed_mps: float | None
    heading_deg: float | None
    distance_delta_m: float | None
    motion_state: str | None


@dataclass(frozen=True)
class ParsedSlopesArchive:
    source_path: Path
    resort_name: str
    started_at: datetime
    ended_at: datetime
    duration_s: int
    distance_m: float | None
    max_speed_mps: float | None
    avg_speed_mps: float | None
    elevation_gain_m: int | None
    elevation_loss_m: int | None
    points: tuple[ParsedSlopesPoint, ...]


@dataclass(frozen=True)
class SlopesImportFileResult:
    file_name: str
    resort_name: str
    started_at: datetime
    ended_at: datetime
    point_count: int
    status: str
    session_id: UUID | None = None


@dataclass(frozen=True)
class SlopesImportSummary:
    user_email: str
    discovered_files: int
    imported_files: int
    repaired_files: int
    skipped_files: int
    total_points_seen: int
    total_points_imported: int
    file_results: tuple[SlopesImportFileResult, ...]


class SlopesImportService:
    def __init__(self, db: Session) -> None:
        self._db = db

    def import_directory(
        self,
        *,
        source_dir: Path,
        user_email: str,
        dry_run: bool = False,
        repair_existing: bool = False,
    ) -> SlopesImportSummary:
        normalized_dir = source_dir.expanduser().resolve()
        if not normalized_dir.exists():
            raise ValueError(f"Source directory does not exist: {normalized_dir}")
        if not normalized_dir.is_dir():
            raise ValueError(f"Source path is not a directory: {normalized_dir}")

        user = self._get_required_user(user_email)
        file_paths = sorted(normalized_dir.glob(_SOURCE_GLOB))
        if not file_paths:
            raise ValueError(f"No .slopes files found in {normalized_dir}")

        file_results: list[SlopesImportFileResult] = []
        imported_files = 0
        repaired_files = 0
        total_points_imported = 0

        for file_path in file_paths:
            parsed = parse_slopes_archive(file_path)
            total_point_count = len(parsed.points)
            resort = self._get_required_resort_by_name(parsed.resort_name)
            existing = self._find_existing_session(
                user_id=user.id,
                resort_id=resort.id,
                started_at=parsed.started_at,
                ended_at=parsed.ended_at,
            )

            if existing is not None:
                if repair_existing:
                    if dry_run:
                        file_results.append(
                            SlopesImportFileResult(
                                file_name=file_path.name,
                                resort_name=parsed.resort_name,
                                started_at=parsed.started_at,
                                ended_at=parsed.ended_at,
                                point_count=total_point_count,
                                status="dry_run_repair_ready",
                                session_id=existing.id,
                            )
                        )
                        continue

                    try:
                        self._repair_existing_session(
                            ride_session=existing,
                            resort_id=resort.id,
                            parsed=parsed,
                        )
                    except Exception:
                        self._db.rollback()
                        raise

                    repaired_files += 1
                    total_points_imported += total_point_count
                    file_results.append(
                        SlopesImportFileResult(
                            file_name=file_path.name,
                            resort_name=parsed.resort_name,
                            started_at=parsed.started_at,
                            ended_at=parsed.ended_at,
                            point_count=total_point_count,
                            status="repaired",
                            session_id=existing.id,
                        )
                    )
                    continue

                file_results.append(
                    SlopesImportFileResult(
                        file_name=file_path.name,
                        resort_name=parsed.resort_name,
                        started_at=parsed.started_at,
                        ended_at=parsed.ended_at,
                        point_count=total_point_count,
                        status="skipped_existing",
                        session_id=existing.id,
                    )
                )
                continue

            if dry_run:
                file_results.append(
                    SlopesImportFileResult(
                        file_name=file_path.name,
                        resort_name=parsed.resort_name,
                        started_at=parsed.started_at,
                        ended_at=parsed.ended_at,
                        point_count=total_point_count,
                        status="dry_run_ready",
                    )
                )
                continue

            ride_session = RideSession(
                user_id=user.id,
                resort_id=resort.id,
                started_at=parsed.started_at,
                ended_at=parsed.ended_at,
                duration_s=parsed.duration_s,
                distance_m=parsed.distance_m,
                max_speed_mps=parsed.max_speed_mps,
                avg_speed_mps=parsed.avg_speed_mps,
                elevation_gain_m=parsed.elevation_gain_m,
                elevation_loss_m=parsed.elevation_loss_m,
                status=RideSessionStatus.COMPLETED,
            )

            try:
                self._db.add(ride_session)
                self._db.flush()
                self._db.add_all(build_session_points(ride_session.id, parsed.points))
                self._db.commit()
            except Exception:
                self._db.rollback()
                raise

            imported_files += 1
            total_points_imported += total_point_count
            file_results.append(
                SlopesImportFileResult(
                    file_name=file_path.name,
                    resort_name=parsed.resort_name,
                    started_at=parsed.started_at,
                    ended_at=parsed.ended_at,
                    point_count=total_point_count,
                    status="imported",
                    session_id=ride_session.id,
                )
            )

        skipped_files = len(file_paths) - imported_files - repaired_files
        return SlopesImportSummary(
            user_email=user.email,
            discovered_files=len(file_paths),
            imported_files=imported_files,
            repaired_files=repaired_files,
            skipped_files=skipped_files,
            total_points_seen=sum(result.point_count for result in file_results),
            total_points_imported=total_points_imported,
            file_results=tuple(file_results),
        )

    def _get_required_user(self, email: str) -> User:
        stmt = select(User).where(func.lower(User.email) == email.strip().lower())
        user = self._db.scalar(stmt)
        if user is None:
            raise ValueError(f"User not found for email: {email}")
        return user

    def _get_required_resort_by_name(self, name: str) -> Resort:
        stmt = select(Resort).where(func.lower(Resort.name) == name.strip().lower())
        matches = list(self._db.scalars(stmt).all())
        if not matches:
            raise ValueError(f"Resort not found for exact name: {name}")
        if len(matches) > 1:
            raise ValueError(f"Multiple resorts matched exact name {name!r}; refine lookup first.")
        return matches[0]

    def _find_existing_session(
        self,
        *,
        user_id: UUID,
        resort_id: UUID,
        started_at: datetime,
        ended_at: datetime,
    ) -> RideSession | None:
        stmt = select(RideSession).where(
            RideSession.user_id == user_id,
            RideSession.resort_id == resort_id,
            RideSession.started_at == started_at,
            RideSession.ended_at == ended_at,
        )
        return self._db.scalar(stmt)

    def _repair_existing_session(
        self,
        *,
        ride_session: RideSession,
        resort_id: UUID,
        parsed: ParsedSlopesArchive,
    ) -> None:
        ride_session.resort_id = resort_id
        ride_session.started_at = parsed.started_at
        ride_session.ended_at = parsed.ended_at
        ride_session.duration_s = parsed.duration_s
        ride_session.distance_m = parsed.distance_m
        ride_session.max_speed_mps = parsed.max_speed_mps
        ride_session.avg_speed_mps = parsed.avg_speed_mps
        ride_session.elevation_gain_m = parsed.elevation_gain_m
        ride_session.elevation_loss_m = parsed.elevation_loss_m
        ride_session.status = RideSessionStatus.COMPLETED

        self._db.execute(
            delete(SessionPoint).where(SessionPoint.session_id == ride_session.id)
        )
        self._db.flush()
        self._db.add_all(build_session_points(ride_session.id, parsed.points))
        self._db.commit()


def parse_slopes_archive(source_path: Path) -> ParsedSlopesArchive:
    with zipfile.ZipFile(source_path) as archive:
        metadata_xml = _read_required_entry(archive, _METADATA_ENTRY_NAME)
        gps_csv = _read_required_entry(archive, _GPS_ENTRY_NAME)

    return parse_slopes_payload(
        source_path=source_path,
        metadata_xml=metadata_xml,
        gps_csv_text=gps_csv,
    )


def parse_slopes_payload(
    *,
    source_path: Path,
    metadata_xml: str,
    gps_csv_text: str,
) -> ParsedSlopesArchive:
    activity = ET.fromstring(metadata_xml)
    resort_name = _require_attribute(activity, "locationName", source_path)
    started_at = _parse_slopes_datetime(_require_attribute(activity, "recordStart", source_path))
    ended_at = _parse_slopes_datetime(_require_attribute(activity, "recordEnd", source_path))
    if ended_at < started_at:
        raise ValueError(f"recordEnd is earlier than recordStart in {source_path.name}")

    duration_s = int((ended_at - started_at).total_seconds())
    distance_m = _parse_optional_float(activity.attrib.get("distance"))
    max_speed_mps = _parse_optional_float(activity.attrib.get("topSpeed"))
    avg_speed_mps = None
    if distance_m is not None and duration_s > 0:
        avg_speed_mps = distance_m / duration_s

    override_segments = parse_override_segments(activity.attrib.get("overrides", ""))
    action_segments = parse_action_segments(activity.findall("./actions/Action"))
    motion_segments = _combine_motion_segments(
        override_segments=override_segments,
        action_segments=action_segments,
    )
    points = parse_gps_points(
        gps_csv_text=gps_csv_text,
        record_start=started_at,
        record_end=ended_at,
        motion_segments=motion_segments,
    )
    elevation_gain_m, elevation_loss_m = _compute_elevation_metrics(activity.findall("./actions/Action"))

    return ParsedSlopesArchive(
        source_path=source_path,
        resort_name=resort_name,
        started_at=started_at,
        ended_at=ended_at,
        duration_s=duration_s,
        distance_m=distance_m,
        max_speed_mps=max_speed_mps,
        avg_speed_mps=avg_speed_mps,
        elevation_gain_m=elevation_gain_m,
        elevation_loss_m=elevation_loss_m,
        points=tuple(points),
    )


def parse_override_segments(raw_overrides: str) -> tuple[SlopesOverrideSegment, ...]:
    if not raw_overrides.strip():
        return ()

    segments: list[SlopesOverrideSegment] = []
    for raw_segment in raw_overrides.split(";"):
        normalized_segment = raw_segment.strip()
        if not normalized_segment:
            continue

        range_part, _, state_part = normalized_segment.partition(":")
        if not range_part or not state_part:
            raise ValueError(f"Invalid override segment: {normalized_segment}")

        start_raw, _, end_raw = range_part.partition("-")
        if not start_raw or not end_raw:
            raise ValueError(f"Invalid override time range: {normalized_segment}")

        motion_state = _MOTION_STATE_BY_OVERRIDE.get(state_part.strip().lower())
        if motion_state is None:
            raise ValueError(f"Unsupported override state: {state_part.strip()}")

        start_epoch_s = int(start_raw)
        end_epoch_s = int(end_raw)
        if end_epoch_s < start_epoch_s:
            raise ValueError(f"Override end precedes start: {normalized_segment}")

        segments.append(
            SlopesOverrideSegment(
                start_epoch_s=start_epoch_s,
                end_epoch_s=end_epoch_s,
                motion_state=motion_state,
                priority=_OVERRIDE_SEGMENT_PRIORITY,
            )
        )

    return tuple(segments)


def parse_action_segments(actions: Iterable[ET.Element]) -> tuple[SlopesOverrideSegment, ...]:
    segments: list[SlopesOverrideSegment] = []
    for action in actions:
        action_type = action.attrib.get("type", "").strip().lower()
        motion_state = _MOTION_STATE_BY_ACTION_TYPE.get(action_type)
        if motion_state is None:
            continue

        start_raw = action.attrib.get("start")
        end_raw = action.attrib.get("end")
        if start_raw is None or end_raw is None:
            continue

        start_epoch_s = int(_parse_slopes_datetime(start_raw).timestamp())
        end_epoch_s = int(_parse_slopes_datetime(end_raw).timestamp())
        if end_epoch_s < start_epoch_s:
            continue

        segments.append(
            SlopesOverrideSegment(
                start_epoch_s=start_epoch_s,
                end_epoch_s=end_epoch_s,
                motion_state=motion_state,
                priority=_ACTION_SEGMENT_PRIORITY,
            )
        )

    return tuple(segments)


def _combine_motion_segments(
    *,
    override_segments: Iterable[SlopesOverrideSegment],
    action_segments: Iterable[SlopesOverrideSegment],
) -> tuple[SlopesOverrideSegment, ...]:
    return tuple(
        sorted(
            [*override_segments, *action_segments],
            key=lambda segment: (segment.priority, segment.start_epoch_s, segment.end_epoch_s),
            reverse=True,
        )
    )


def parse_gps_points(
    *,
    gps_csv_text: str,
    record_start: datetime,
    record_end: datetime,
    motion_segments: Iterable[SlopesOverrideSegment],
) -> list[ParsedSlopesPoint]:
    record_start_epoch_s = record_start.timestamp()
    record_start_floor_s = int(record_start_epoch_s)
    record_end_floor_s = int(record_end.timestamp())
    segments = list(motion_segments)

    parsed_points: list[ParsedSlopesPoint] = []
    seen_offsets_ms: set[int] = set()
    csv_reader = csv.reader(io.StringIO(gps_csv_text))
    previous_point: ParsedSlopesPoint | None = None

    for row in csv_reader:
        if not row:
            continue
        if len(row) < 6:
            raise ValueError(f"GPS.csv row must have at least 6 columns, got {len(row)}")

        epoch_s = float(row[0])
        epoch_floor_s = int(epoch_s)
        if epoch_floor_s < record_start_floor_s or epoch_floor_s > record_end_floor_s:
            continue

        t_offset_ms = round((epoch_s - record_start_epoch_s) * 1000)
        if t_offset_ms < 0 or t_offset_ms in seen_offsets_ms:
            continue

        heading_deg = _normalize_heading(_parse_optional_float(row[4]))
        speed_mps = _normalize_non_negative_float(_parse_optional_float(row[5]))
        current_point = ParsedSlopesPoint(
            t_offset_ms=t_offset_ms,
            recorded_at=datetime.fromtimestamp(epoch_s, tz=UTC),
            latitude=float(row[1]),
            longitude=float(row[2]),
            altitude_m=_parse_optional_float(row[3]),
            speed_mps=speed_mps,
            heading_deg=heading_deg,
            distance_delta_m=_distance_delta_meters(
                previous_point=previous_point,
                latitude=float(row[1]),
                longitude=float(row[2]),
            ),
            motion_state=_motion_state_for_epoch_second(epoch_floor_s, segments),
        )
        parsed_points.append(current_point)
        previous_point = current_point
        seen_offsets_ms.add(t_offset_ms)

    if not parsed_points:
        raise ValueError("No GPS points within recordStart/recordEnd window.")

    return parsed_points


def build_session_points(
    session_id: UUID,
    parsed_points: Iterable[ParsedSlopesPoint],
) -> list[SessionPoint]:
    models: list[SessionPoint] = []
    for parsed_point in parsed_points:
        model = SessionPoint(
            session_id=session_id,
            t_offset_ms=parsed_point.t_offset_ms,
            recorded_at=parsed_point.recorded_at,
            latitude=parsed_point.latitude,
            longitude=parsed_point.longitude,
            altitude_m=parsed_point.altitude_m,
            speed_mps=parsed_point.speed_mps,
            heading_deg=parsed_point.heading_deg,
            provider=_PROVIDER_GPS,
        )
        models.append(model)
    return models


def _read_required_entry(archive: zipfile.ZipFile, entry_name: str) -> str:
    try:
        with archive.open(entry_name) as handle:
            return handle.read().decode("utf-8")
    except KeyError as exc:
        raise ValueError(f"{archive.filename} is missing {entry_name}") from exc


def _require_attribute(element: ET.Element, attribute_name: str, source_path: Path) -> str:
    value = element.attrib.get(attribute_name)
    if value is None or not value.strip():
        raise ValueError(f"{source_path.name} is missing metadata attribute {attribute_name}")
    return value


def _parse_slopes_datetime(value: str) -> datetime:
    return datetime.strptime(value, _SLOPES_DATETIME_FORMAT).astimezone(UTC)


def _parse_optional_float(value: str | None) -> float | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    return float(normalized)


def _normalize_heading(value: float | None) -> float | None:
    if value is None:
        return None
    if 0 <= value <= 360:
        return value
    return None


def _normalize_non_negative_float(value: float | None) -> float | None:
    if value is None:
        return None
    if value < 0:
        return None
    return value


def _motion_state_for_epoch_second(
    epoch_second: int,
    segments: Iterable[SlopesOverrideSegment],
) -> str | None:
    has_segments = False
    for segment in segments:
        has_segments = True
        if segment.start_epoch_s <= epoch_second <= segment.end_epoch_s:
            return segment.motion_state
    if has_segments:
        return "stopped_idle"
    return None


def _distance_delta_meters(
    *,
    previous_point: ParsedSlopesPoint | None,
    latitude: float,
    longitude: float,
) -> float:
    if previous_point is None:
        return 0.0

    return haversine_distance_meters(
        previous_point.latitude,
        previous_point.longitude,
        latitude,
        longitude,
    )


def haversine_distance_meters(
    start_lat: float,
    start_lng: float,
    end_lat: float,
    end_lng: float,
) -> float:
    earth_radius_m = 6371000.0
    start_lat_rad = math.radians(start_lat)
    end_lat_rad = math.radians(end_lat)
    delta_lat = math.radians(end_lat - start_lat)
    delta_lng = math.radians(end_lng - start_lng)

    a = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(start_lat_rad)
        * math.cos(end_lat_rad)
        * math.sin(delta_lng / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return earth_radius_m * c


def _compute_elevation_metrics(actions: Iterable[ET.Element]) -> tuple[int | None, int | None]:
    elevation_gain = 0.0
    elevation_loss = 0.0

    for action in actions:
        vertical = _parse_optional_float(action.attrib.get("vertical"))
        if vertical is None:
            continue

        action_type = action.attrib.get("type", "").strip().lower()
        if action_type == "lift":
            elevation_gain += abs(vertical)
        elif action_type == "run":
            elevation_loss += abs(vertical)

    gain_value = round(elevation_gain) if elevation_gain > 0 else None
    loss_value = round(elevation_loss) if elevation_loss > 0 else None
    return gain_value, loss_value
