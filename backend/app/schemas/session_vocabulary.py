CANONICAL_MOTION_STATES = frozenset(
    {
        "initializing_fix",
        "active_descent",
        "lift_uphill",
        "stopped_idle",
        "low_confidence_recovery",
    }
)

CANONICAL_QUALITY_CLASSES = frozenset(
    {
        "accept",
        "accept_low_confidence",
        "reject",
    }
)

CANONICAL_PROVIDERS = frozenset(
    {
        "gps",
        "fused",
        "network",
        "passive",
        "unknown",
    }
)


def normalize_motion_state(value: str | None) -> str | None:
    normalized = _normalize_token(value)
    if normalized is None:
        return None
    if normalized in CANONICAL_MOTION_STATES:
        return normalized
    raise ValueError("motion_state must be one of: " + ", ".join(sorted(CANONICAL_MOTION_STATES)))


def normalize_quality_class(value: str | None) -> str | None:
    normalized = _normalize_token(value)
    if normalized is None:
        return None
    if normalized in CANONICAL_QUALITY_CLASSES:
        return normalized
    raise ValueError(
        "quality_class must be one of: " + ", ".join(sorted(CANONICAL_QUALITY_CLASSES))
    )


def normalize_provider(value: str | None) -> str | None:
    normalized = _normalize_token(value)
    if normalized is None:
        return None
    if normalized in CANONICAL_PROVIDERS:
        return normalized
    if normalized in {"flp", "fusedlocationprovider", "fused_location_provider"}:
        return "fused"
    if normalized in {"cell", "cellular"}:
        return "network"
    return "unknown"


def _normalize_token(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip().lower().replace("-", "_").replace(" ", "_")
    if not normalized:
        return None
    return normalized
