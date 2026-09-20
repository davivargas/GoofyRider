"""Pure entity matching between a source record and catalog resorts (spec 5.4)."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import difflib
from enum import StrEnum
import re
from typing import Any
import unicodedata
import uuid

from app.services.catalog_types import BBox
from app.services.resort_geometry import haversine_m
from app.services.resort_geometry import point_in_bbox
from app.services.resort_geometry import point_in_geometry

NAME_WEIGHT = 0.55
DISTANCE_WEIGHT = 0.35
COUNTRY_WEIGHT = 0.10
AUTO_SCORE = 0.85
AUTO_MARGIN = 0.15
AUTO_MAX_DISTANCE_M = 5_000.0
REVIEW_SCORE = 0.5
DISTANCE_ZERO_M = 10_000.0
PREFILTER_DEGREES = 0.5
MAX_CANDIDATES = 5

_GENERIC_TOKENS = frozenset(
    {"ski", "resort", "area", "mountain", "mount", "mont", "mt", "station", "skigebiet", "domaine"}
)
_NON_WORD = re.compile(r"[^a-z0-9]+")


class MatchKind(StrEnum):
    AUTO = "auto"
    PENDING_REVIEW = "pending_review"
    NONE = "none"


@dataclass(frozen=True)
class MatchQuery:
    name: str | None
    latitude: float | None
    longitude: float | None
    country_code: str | None
    boundary: dict[str, Any] | None = None


@dataclass(frozen=True)
class ResortCandidate:
    resort_id: uuid.UUID
    name: str
    name_aliases: tuple[str, ...]
    latitude: float | None
    longitude: float | None
    bbox: BBox | None
    boundary: dict[str, Any] | None
    country_code: str | None
    has_primary_record: bool


@dataclass(frozen=True)
class CandidateScore:
    resort_id: uuid.UUID
    name: str
    score: float
    distance_m: float | None
    name_similarity: float
    inside_boundary: bool

    def to_json(self) -> dict[str, Any]:
        return {
            "resort_id": str(self.resort_id),
            "name": self.name,
            "score": round(self.score, 4),
            "distance_m": None if self.distance_m is None else round(self.distance_m, 1),
            "name_similarity": round(self.name_similarity, 4),
            "inside_boundary": self.inside_boundary,
        }


@dataclass(frozen=True)
class MatchDecision:
    kind: MatchKind
    resort_id: uuid.UUID | None
    score: float | None
    candidates: tuple[CandidateScore, ...]


def normalize_name(name: str) -> str:
    folded = (
        unicodedata.normalize("NFKD", name.casefold()).encode("ascii", "ignore").decode("ascii")
    )
    tokens = [t for t in _NON_WORD.split(folded) if t and t not in _GENERIC_TOKENS]
    return " ".join(tokens)


def name_similarity(a: str, b: str) -> float:
    left, right = normalize_name(a), normalize_name(b)
    if not left or not right:
        return 0.0
    ratio = difflib.SequenceMatcher(None, left, right).ratio()
    left_tokens, right_tokens = set(left.split()), set(right.split())
    union = left_tokens | right_tokens
    jaccard = len(left_tokens & right_tokens) / len(union) if union else 0.0
    return min(1.0, 0.6 * ratio + 0.4 * jaccard)


def _country_term(a: str | None, b: str | None) -> float:
    if a is None or b is None:
        return 0.5
    return 1.0 if a.upper() == b.upper() else 0.0


def _in_prefilter(query: MatchQuery, candidate: ResortCandidate) -> bool:
    if query.latitude is None or query.longitude is None:
        return True
    if candidate.bbox is not None:
        min_lat, min_lon, max_lat, max_lon = candidate.bbox
        return (
            min_lat - PREFILTER_DEGREES <= query.latitude <= max_lat + PREFILTER_DEGREES
            and min_lon - PREFILTER_DEGREES <= query.longitude <= max_lon + PREFILTER_DEGREES
        )
    if candidate.latitude is None or candidate.longitude is None:
        return True
    return (
        abs(candidate.latitude - query.latitude) <= PREFILTER_DEGREES
        and abs(candidate.longitude - query.longitude) <= PREFILTER_DEGREES
    )


def _score(query: MatchQuery, candidate: ResortCandidate) -> CandidateScore:
    names = (candidate.name, *candidate.name_aliases)
    similarity = max(name_similarity(query.name or "", n) for n in names) if query.name else 0.0

    distance_m: float | None = None
    inside = False
    distance_term = 0.0
    if query.latitude is not None and query.longitude is not None:
        if candidate.boundary is not None and candidate.bbox is not None:
            inside = point_in_bbox(
                query.latitude, query.longitude, candidate.bbox
            ) and point_in_geometry(query.latitude, query.longitude, candidate.boundary)
        if (
            not inside
            and query.boundary is not None
            and candidate.latitude is not None
            and candidate.longitude is not None
        ):
            inside = point_in_geometry(candidate.latitude, candidate.longitude, query.boundary)
        if candidate.latitude is not None and candidate.longitude is not None:
            distance_m = haversine_m(
                query.latitude, query.longitude, candidate.latitude, candidate.longitude
            )
        if inside:
            distance_term = 1.0
        elif distance_m is not None:
            distance_term = max(0.0, 1.0 - distance_m / DISTANCE_ZERO_M)

    score = (
        NAME_WEIGHT * similarity
        + DISTANCE_WEIGHT * distance_term
        + COUNTRY_WEIGHT * _country_term(query.country_code, candidate.country_code)
    )
    return CandidateScore(
        resort_id=candidate.resort_id,
        name=candidate.name,
        score=score,
        distance_m=distance_m,
        name_similarity=similarity,
        inside_boundary=inside,
    )


def match_resort(
    query: MatchQuery,
    candidates: Sequence[ResortCandidate],
    *,
    legacy_must_review: bool = False,
) -> MatchDecision:
    scored = [_score(query, c) for c in candidates if _in_prefilter(query, c)]
    scored.sort(key=lambda s: (-s.score, str(s.resort_id)))
    top = tuple(scored[:MAX_CANDIDATES])

    if top:
        best = top[0]
        runner_up = top[1].score if len(top) > 1 else 0.0
        close_enough = best.inside_boundary or (
            best.distance_m is not None and best.distance_m <= AUTO_MAX_DISTANCE_M
        )
        if best.score >= AUTO_SCORE and best.score - runner_up >= AUTO_MARGIN and close_enough:
            return MatchDecision(MatchKind.AUTO, best.resort_id, best.score, top)
        if best.score >= REVIEW_SCORE:
            return MatchDecision(MatchKind.PENDING_REVIEW, None, best.score, top)

    if legacy_must_review:
        return MatchDecision(MatchKind.PENDING_REVIEW, None, top[0].score if top else None, top)
    return MatchDecision(MatchKind.NONE, None, None, top)
