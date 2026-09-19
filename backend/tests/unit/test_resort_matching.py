import uuid

from app.services.resort_matching import MatchKind
from app.services.resort_matching import MatchQuery
from app.services.resort_matching import ResortCandidate
from app.services.resort_matching import match_resort
from app.services.resort_matching import name_similarity
from app.services.resort_matching import normalize_name

GROUSE_ID = uuid.UUID("00000000-0000-0000-0000-000000000001")
CYPRESS_ID = uuid.UUID("00000000-0000-0000-0000-000000000002")
GROUSE_US_ID = uuid.UUID("00000000-0000-0000-0000-000000000003")
GROUSE_BOUNDARY = {
    "type": "Polygon",
    "coordinates": [
        [
            [-123.095, 49.372],
            [-123.068, 49.372],
            [-123.068, 49.392],
            [-123.095, 49.392],
            [-123.095, 49.372],
        ]
    ],
}


def _candidate(
    resort_id: uuid.UUID,
    name: str,
    lat: float,
    lon: float,
    *,
    country: str | None = "CA",
    aliases: tuple[str, ...] = (),
    boundary: dict | None = None,  # type: ignore[type-arg]
    has_primary: bool = False,
) -> ResortCandidate:
    bbox = None
    if boundary is not None:
        ring = boundary["coordinates"][0]
        bbox = (
            min(p[1] for p in ring),
            min(p[0] for p in ring),
            max(p[1] for p in ring),
            max(p[0] for p in ring),
        )
    return ResortCandidate(
        resort_id=resort_id,
        name=name,
        name_aliases=aliases,
        latitude=lat,
        longitude=lon,
        bbox=bbox,
        boundary=boundary,
        country_code=country,
        has_primary_record=has_primary,
    )


CANDIDATES = [
    _candidate(GROUSE_ID, "Grouse Mountain", 49.380, -123.081, boundary=GROUSE_BOUNDARY),
    _candidate(CYPRESS_ID, "Cypress Mountain", 49.396, -123.204),
    _candidate(GROUSE_US_ID, "Grouse Mountain", 45.0, -110.0, country="US"),
]


def test_normalize_name_strips_case_accents_punctuation_and_generic_tokens() -> None:
    assert normalize_name("Whistler Blackcomb Ski Resort") == "whistler blackcomb"
    assert normalize_name("Mont-Sainte-Anne (Station)") == "sainte anne"
    assert normalize_name("  Mt. Seymour ") == "seymour"


def test_name_similarity_bounds() -> None:
    assert name_similarity("Grouse Mountain", "Grouse Mountain Resort") == 1.0
    assert name_similarity("Grouse Mountain", "Cypress Mountain") < 0.5
    assert 0.0 <= name_similarity("", "Anything") <= 1.0


def test_auto_match_same_name_inside_boundary() -> None:
    query = MatchQuery(
        name="Grouse Mountain Resort", latitude=49.381, longitude=-123.080, country_code="CA"
    )

    decision = match_resort(query, CANDIDATES)

    assert decision.kind is MatchKind.AUTO
    assert decision.resort_id == GROUSE_ID
    assert decision.score is not None and decision.score >= 0.85
    assert decision.candidates[0].inside_boundary is True


def test_same_name_far_away_in_other_country_is_not_auto() -> None:
    query = MatchQuery(name="Grouse Mountain", latitude=45.0, longitude=-110.0, country_code="US")

    decision = match_resort(query, CANDIDATES)

    assert decision.kind is MatchKind.AUTO and decision.resort_id == GROUSE_US_ID


def test_similar_name_but_too_far_is_pending_review() -> None:
    query = MatchQuery(
        name="Grouse Mountain", latitude=49.45, longitude=-123.081, country_code="CA"
    )

    decision = match_resort(query, CANDIDATES)

    assert decision.kind is MatchKind.PENDING_REVIEW
    assert next(c.resort_id for c in decision.candidates) == GROUSE_ID


def test_unrelated_query_is_none() -> None:
    query = MatchQuery(name="Big White", latitude=49.72, longitude=-118.93, country_code="CA")

    assert match_resort(query, CANDIDATES).kind is MatchKind.NONE


def test_legacy_must_review_never_returns_none() -> None:
    query = MatchQuery(name="Big White", latitude=49.72, longitude=-118.93, country_code="CA")

    decision = match_resort(query, CANDIDATES, legacy_must_review=True)

    assert decision.kind is MatchKind.PENDING_REVIEW
    assert decision.resort_id is None


def test_margin_rule_sends_close_pair_to_review() -> None:
    twin_a = _candidate(GROUSE_ID, "Sun Peaks", 50.88, -119.89)
    twin_b = _candidate(CYPRESS_ID, "Sun Peaks", 50.881, -119.891)
    query = MatchQuery(name="Sun Peaks", latitude=50.8805, longitude=-119.8905, country_code="CA")

    decision = match_resort(query, [twin_a, twin_b])

    assert decision.kind is MatchKind.PENDING_REVIEW
    assert len(decision.candidates) == 2


def test_tie_break_is_deterministic_by_resort_id() -> None:
    twin_a = _candidate(CYPRESS_ID, "Sun Peaks", 50.88, -119.89)
    twin_b = _candidate(GROUSE_ID, "Sun Peaks", 50.88, -119.89)
    query = MatchQuery(name="Sun Peaks", latitude=50.88, longitude=-119.89, country_code="CA")

    first = match_resort(query, [twin_a, twin_b])
    second = match_resort(query, [twin_b, twin_a])

    assert [c.resort_id for c in first.candidates] == [GROUSE_ID, CYPRESS_ID]
    assert [c.resort_id for c in second.candidates] == [GROUSE_ID, CYPRESS_ID]


def test_alias_counts_for_name_similarity() -> None:
    aliased = _candidate(
        CYPRESS_ID, "Cypress", 49.396, -123.204, aliases=("Cypress Mountain Resort",)
    )
    query = MatchQuery(
        name="Cypress Mountain Resort", latitude=49.396, longitude=-123.204, country_code="CA"
    )

    decision = match_resort(query, [aliased])

    assert decision.kind is MatchKind.AUTO


def test_query_without_point_scores_by_name_and_country_only() -> None:
    query = MatchQuery(name="Cypress Mountain", latitude=None, longitude=None, country_code="CA")

    decision = match_resort(query, CANDIDATES)

    assert decision.kind is MatchKind.PENDING_REVIEW
    assert decision.candidates[0].resort_id == CYPRESS_ID
    assert decision.candidates[0].distance_m is None
