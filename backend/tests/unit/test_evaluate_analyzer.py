from app.scripts.evaluate_analyzer import CORPUS_DIR
from app.scripts.evaluate_analyzer import load_archive
from app.scripts.evaluate_analyzer import score_archive
from app.services.analysis import AnalyzerConfig
from app.services.analysis import SessionAnalyzer


def test_corpus_has_fourteen_archives() -> None:
    assert len(sorted(CORPUS_DIR.glob("*.slopes"))) == 14


def test_archive_loads_points_with_accuracy_and_labels() -> None:
    archive = load_archive(CORPUS_DIR / "cypress_2025-01-03.slopes")
    assert len(archive.points) > 500
    assert archive.points[0].accuracy_m is not None
    assert archive.points[0].vertical_accuracy_m is not None
    assert {label.kind for label in archive.labels} == {"run", "lift"}
    assert archive.labels == sorted(archive.labels, key=lambda label: label.started_at)


def test_label_override_removes_the_plateau_walk_lift() -> None:
    archive = load_archive(CORPUS_DIR / "grouse_2026-03-13.slopes")
    durations = [
        (label.ended_at - label.started_at).total_seconds()
        for label in archive.labels
        if label.kind == "lift"
    ]
    assert max(durations) < 1200


def test_scoring_the_cleanest_archive() -> None:
    archive = load_archive(CORPUS_DIR / "cypress_2025-01-03.slopes")
    analyzer = SessionAnalyzer(analyzer_version="test", config=AnalyzerConfig())
    score = score_archive(archive, analyzer, lifts=())
    assert score.ref_runs == 3 and score.ref_lifts == 3
    assert 0.0 <= score.agreement <= 1.0
    assert score.agreement > 0.9
