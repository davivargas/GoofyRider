"""Score the session analyzer against the Slopes corpus.

Usage (from backend/):
    python -m app.scripts.evaluate_analyzer [--no-catalog] [--config key=value ...]
                                            [--write-expected] [--json PATH]
"""

from __future__ import annotations

from argparse import ArgumentParser
from collections.abc import Sequence
import csv
from dataclasses import asdict
from dataclasses import dataclass
from datetime import UTC
from datetime import datetime
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

from app.services.analysis import AnalyzerConfig
from app.services.analysis import AnalyzerInput
from app.services.analysis import RawPoint
from app.services.analysis import ResortLift
from app.services.analysis import SessionAnalyzer
from app.services.analysis import SessionMetadataInput
from app.services.analysis.config import parse_overrides
from app.services.openskidata_mapping import map_lift

_BACKEND_DIR = Path(__file__).resolve().parents[2]
CORPUS_DIR = _BACKEND_DIR / "tests" / "fixtures" / "slopes"
CORPUS_LIFTS = _BACKEND_DIR / "tests" / "fixtures" / "openskidata" / "corpus_lifts.geojson"
OVERRIDES_PATH = CORPUS_DIR / "label_overrides.json"
EXPECTED_PATH = CORPUS_DIR / "expected_scores.json"
EXPECTED_NO_CATALOG_PATH = CORPUS_DIR / "expected_scores_no_catalog.json"
_SLOPES_DT = "%Y-%m-%d %H:%M:%S %z"
_MATCH_OVERLAP = 0.5


@dataclass(frozen=True)
class LabelledAction:
    kind: str
    started_at: datetime
    ended_at: datetime


@dataclass(frozen=True)
class CorpusArchive:
    name: str
    record_start: datetime
    record_end: datetime
    points: list[RawPoint]
    labels: list[LabelledAction]


@dataclass(frozen=True)
class ArchiveScore:
    name: str
    agreement: float
    runs: int
    ref_runs: int
    lifts: int
    ref_lifts: int
    lift_found: int
    lift_correct: int
    run_found: int
    run_correct: int

    @property
    def exact_counts(self) -> bool:
        return self.runs == self.ref_runs and self.lifts == self.ref_lifts


@dataclass(frozen=True)
class CorpusScore:
    archives: list[ArchiveScore]

    @property
    def mean_agreement(self) -> float:
        return sum(a.agreement for a in self.archives) / len(self.archives)

    @property
    def exact_count_archives(self) -> int:
        return sum(1 for a in self.archives if a.exact_counts)

    @property
    def lift_recall(self) -> float:
        return sum(a.lift_found for a in self.archives) / max(
            1, sum(a.ref_lifts for a in self.archives)
        )

    @property
    def lift_precision(self) -> float:
        return sum(a.lift_correct for a in self.archives) / max(
            1, sum(a.lifts for a in self.archives)
        )

    @property
    def run_recall(self) -> float:
        return sum(a.run_found for a in self.archives) / max(
            1, sum(a.ref_runs for a in self.archives)
        )

    @property
    def run_precision(self) -> float:
        return sum(a.run_correct for a in self.archives) / max(
            1, sum(a.runs for a in self.archives)
        )


def load_archive(path: Path) -> CorpusArchive:
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read("Metadata.xml"))
        gps_text = archive.read("GPS.csv").decode("utf-8")
    record_start = datetime.strptime(root.attrib["recordStart"], _SLOPES_DT)
    record_end = datetime.strptime(root.attrib["recordEnd"], _SLOPES_DT)
    corrections = {
        entry["action_start"]: entry["corrected"]
        for entry in json.loads(OVERRIDES_PATH.read_text(encoding="utf-8"))
        if entry["archive"] == path.stem
    }
    labels: list[LabelledAction] = []
    actions_root = root.find("actions")
    for action in actions_root if actions_root is not None else []:
        kind = corrections.get(action.attrib["start"], action.attrib["type"].lower())
        if kind not in ("run", "lift"):
            continue
        labels.append(
            LabelledAction(
                kind=kind,
                started_at=datetime.strptime(action.attrib["start"], _SLOPES_DT),
                ended_at=datetime.strptime(action.attrib["end"], _SLOPES_DT),
            )
        )
    labels.sort(key=lambda label: label.started_at)

    points: list[RawPoint] = []
    start_epoch, end_epoch = record_start.timestamp(), record_end.timestamp()
    for row in csv.reader(io.StringIO(gps_text)):
        if len(row) < 8:
            continue
        epoch = float(row[0])
        if epoch < start_epoch - 1 or epoch > end_epoch + 1:
            continue
        points.append(
            RawPoint(
                t_offset_ms=max(0, round((epoch - start_epoch) * 1000)),
                recorded_at=datetime.fromtimestamp(epoch, tz=UTC),
                latitude=float(row[1]),
                longitude=float(row[2]),
                altitude_m=float(row[3]),
                speed_mps=max(0.0, float(row[5])),
                accuracy_m=float(row[6]),
                vertical_accuracy_m=float(row[7]),
                heading_deg=float(row[4]) if float(row[4]) >= 0 else None,
            )
        )
    return CorpusArchive(path.stem, record_start, record_end, points, labels)


def lifts_for(archive_name: str) -> tuple[ResortLift, ...]:
    resort = archive_name.split("_", 1)[0]
    if not CORPUS_LIFTS.exists():
        return ()
    payload = json.loads(CORPUS_LIFTS.read_text(encoding="utf-8"))
    lifts: list[ResortLift] = []
    for feature in payload.get("features", []):
        lift = map_lift(feature)
        if lift is None or f"osd-{resort}" not in lift.ski_area_ids:
            continue
        lifts.append(
            ResortLift(
                name=lift.name,
                polyline=lift.polyline,
                lift_type=lift.lift_type,
                osm_aerialway=lift.osm_aerialway,
                external_track_id=lift.external_track_id,
            )
        )
    return tuple(lifts)


def score_archive(
    archive: CorpusArchive, analyzer: SessionAnalyzer, lifts: Sequence[ResortLift]
) -> ArchiveScore:
    result = analyzer.analyze(
        AnalyzerInput(
            points=archive.points,
            metadata=SessionMetadataInput(
                record_start=archive.record_start,
                record_end=archive.record_end,
                resort_id=None,
                source="live_recording",
            ),
            resort_lifts=tuple(lifts),
        )
    )
    origin = int(archive.points[0].recorded_at.timestamp())
    seconds = int(archive.points[-1].recorded_at.timestamp()) - origin + 1

    def to_spans(
        items: Sequence[tuple[str, datetime, datetime]], kind: str
    ) -> list[tuple[int, int]]:
        clipped = [
            (max(0, int(s.timestamp()) - origin), min(seconds - 1, int(e.timestamp()) - origin))
            for k, s, e in items
            if k == kind
        ]
        # A span wholly outside the point window clips to start > end; it must not be
        # painted and must never count as a match (a non-positive length would make
        # the overlap threshold in matches() trivially satisfied).
        return [(a, b) for a, b in clipped if a <= b]

    ours = [(a.action_type, a.started_at, a.ended_at) for a in result.actions]
    theirs = [(label.kind, label.started_at, label.ended_at) for label in archive.labels]
    spans = {
        (who, kind): to_spans(items, kind)
        for who, items in (("ours", ours), ("ref", theirs))
        for kind in ("run", "lift")
    }

    def paint(who: str) -> list[str]:
        track = ["other"] * seconds
        # Lifts are painted after runs so a lift wins if the two ever overlap; the
        # analyzer never emits overlapping actions today, so this is a tie-break only.
        for kind in ("run", "lift"):
            for a, b in spans[(who, kind)]:
                for i in range(a, b + 1):
                    track[i] = kind
        return track

    mine, reference = paint("ours"), paint("ref")
    agreement = sum(1 for x, y in zip(mine, reference, strict=True) if x == y) / seconds

    def matches(targets: Sequence[tuple[int, int]], pool: Sequence[tuple[int, int]]) -> int:
        hits = 0
        for a, b in targets:
            best = max((min(b, y) - max(a, x) + 1 for x, y in pool), default=0)
            if best >= _MATCH_OVERLAP * (b - a + 1):
                hits += 1
        return hits

    return ArchiveScore(
        name=archive.name,
        agreement=agreement,
        runs=len(spans[("ours", "run")]),
        ref_runs=len(spans[("ref", "run")]),
        lifts=len(spans[("ours", "lift")]),
        ref_lifts=len(spans[("ref", "lift")]),
        lift_found=matches(spans[("ref", "lift")], spans[("ours", "lift")]),
        lift_correct=matches(spans[("ours", "lift")], spans[("ref", "lift")]),
        run_found=matches(spans[("ref", "run")], spans[("ours", "run")]),
        run_correct=matches(spans[("ours", "run")], spans[("ref", "run")]),
    )


def score_corpus(config: AnalyzerConfig, *, use_catalog: bool = True) -> CorpusScore:
    analyzer = SessionAnalyzer(analyzer_version="evaluation", config=config)
    scores = []
    for path in sorted(CORPUS_DIR.glob("*.slopes")):
        archive = load_archive(path)
        scores.append(
            score_archive(archive, analyzer, lifts_for(archive.name) if use_catalog else ())
        )
    return CorpusScore(scores)


def main(argv: Sequence[str] | None = None) -> int:
    parser = ArgumentParser(description="Score the session analyzer against the Slopes corpus.")
    parser.add_argument("--no-catalog", action="store_true")
    parser.add_argument("--config", nargs="*", default=[], metavar="key=value")
    parser.add_argument("--write-expected", action="store_true")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args(argv)

    config = AnalyzerConfig().with_overrides(**parse_overrides(args.config))
    corpus = score_corpus(config, use_catalog=not args.no_catalog)
    for a in corpus.archives:
        flag = "OK" if a.exact_counts else "  "
        print(
            f"{a.name:24s} agree {a.agreement * 100:5.1f}%  runs {a.runs:2d}/{a.ref_runs:2d}  lifts {a.lifts:2d}/{a.ref_lifts:2d} {flag}"
        )
    print(
        f"MEAN {corpus.mean_agreement * 100:.1f}%  exact {corpus.exact_count_archives}/{len(corpus.archives)}  "
        f"lift R {corpus.lift_recall * 100:.1f}% P {corpus.lift_precision * 100:.1f}%  "
        f"run R {corpus.run_recall * 100:.1f}% P {corpus.run_precision * 100:.1f}%"
    )
    payload = {a.name: asdict(a) for a in corpus.archives}
    if args.json is not None:
        args.json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    if args.write_expected:
        # Both configurations are recorded on every re-record: the catalog run is the one
        # the success bar is measured on, the no-catalog run is what live sessions get
        # until the backend passes the lift catalog.
        with_catalog = corpus if not args.no_catalog else score_corpus(config, use_catalog=True)
        without_catalog = corpus if args.no_catalog else score_corpus(config, use_catalog=False)
        _write_expected(EXPECTED_PATH, with_catalog)
        _write_expected(EXPECTED_NO_CATALOG_PATH, without_catalog)
    return 0


def _write_expected(path: Path, corpus: CorpusScore) -> None:
    path.write_text(
        json.dumps(
            {
                a.name: {"agreement": round(a.agreement, 4), "runs": a.runs, "lifts": a.lifts}
                for a in corpus.archives
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    raise SystemExit(main())
