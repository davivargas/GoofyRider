"""Regression gate for the session analyzer against the Slopes corpus (spec section 9.3)."""

import json

import pytest

from app.scripts.evaluate_analyzer import EXPECTED_NO_CATALOG_PATH
from app.scripts.evaluate_analyzer import EXPECTED_PATH
from app.scripts.evaluate_analyzer import CorpusScore
from app.scripts.evaluate_analyzer import score_corpus
from app.services.analysis import AnalyzerConfig

OLD_ANALYZER_MEAN = 0.784
TOLERANCE = 0.005


@pytest.fixture(scope="module")
def corpus() -> CorpusScore:
    return score_corpus(AnalyzerConfig(), use_catalog=True)


@pytest.fixture(scope="module")
def corpus_no_catalog() -> CorpusScore:
    return score_corpus(AnalyzerConfig(), use_catalog=False)


def test_no_archive_regresses_below_its_recorded_score(corpus: CorpusScore) -> None:
    expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))
    assert set(expected) == {a.name for a in corpus.archives}
    for archive in corpus.archives:
        recorded = expected[archive.name]
        assert archive.agreement >= recorded["agreement"] - TOLERANCE, archive.name
        assert (archive.runs, archive.lifts) == (recorded["runs"], recorded["lifts"]), archive.name


def test_corpus_meets_the_success_bar(corpus: CorpusScore) -> None:
    assert corpus.mean_agreement >= 0.88
    assert min(a.agreement for a in corpus.archives) >= 0.75
    assert corpus.lift_recall >= 0.94
    assert corpus.lift_precision >= 0.93
    assert corpus.run_recall >= 0.90
    assert corpus.exact_count_archives >= 8


def test_corpus_beats_the_old_analyzer(corpus: CorpusScore) -> None:
    assert corpus.mean_agreement > OLD_ANALYZER_MEAN


def test_no_catalog_configuration_does_not_regress(corpus_no_catalog: CorpusScore) -> None:
    # This is the configuration live sessions run today (the backend does not pass the lift
    # catalog yet), so it is gated against regression but not against the success bar.
    expected = json.loads(EXPECTED_NO_CATALOG_PATH.read_text(encoding="utf-8"))
    assert set(expected) == {a.name for a in corpus_no_catalog.archives}
    for archive in corpus_no_catalog.archives:
        recorded = expected[archive.name]
        assert archive.agreement >= recorded["agreement"] - TOLERANCE, archive.name
        assert (archive.runs, archive.lifts) == (recorded["runs"], recorded["lifts"]), archive.name
