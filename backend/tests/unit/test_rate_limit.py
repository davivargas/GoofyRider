from app.core.rate_limit import SWEEP_EVERY
from app.core.rate_limit import InMemoryRateLimiter


def test_allows_up_to_limit_then_rejects_with_retry_after() -> None:
    limiter = InMemoryRateLimiter()

    for i in range(3):
        decision = limiter.check("login", "1.2.3.4", limit=3, window_seconds=60, now=100.0 + i)
        assert decision.allowed is True
        assert decision.retry_after_seconds == 0

    rejected = limiter.check("login", "1.2.3.4", limit=3, window_seconds=60, now=110.0)
    assert rejected.allowed is False
    assert rejected.retry_after_seconds == 50


def test_window_slides_and_old_events_expire() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "k", limit=1, window_seconds=10, now=0.0)

    assert limiter.check("login", "k", limit=1, window_seconds=10, now=9.9).allowed is False
    assert limiter.check("login", "k", limit=1, window_seconds=10, now=10.1).allowed is True


def test_buckets_and_keys_are_isolated() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "a", limit=1, window_seconds=60, now=0.0)

    assert limiter.check("login", "b", limit=1, window_seconds=60, now=0.0).allowed is True
    assert limiter.check("register", "a", limit=1, window_seconds=60, now=0.0).allowed is True
    assert limiter.check("login", "a", limit=1, window_seconds=60, now=0.0).allowed is False


def test_retry_after_is_at_least_one_second() -> None:
    limiter = InMemoryRateLimiter()
    limiter.check("login", "k", limit=1, window_seconds=10, now=0.0)

    assert (
        limiter.check("login", "k", limit=1, window_seconds=10, now=9.99).retry_after_seconds == 1
    )


def test_periodic_sweep_shrinks_map_after_many_stale_keys() -> None:
    limiter = InMemoryRateLimiter()
    window = 10

    for i in range(1001):
        limiter.check("login", f"stale-{i}", limit=100, window_seconds=window, now=0.0)

    assert len(limiter._events) == 1001

    later = window + 100.0
    # Land the next check exactly on the sweep boundary instead of making
    # 999 more throwaway calls just to walk the internal counter there.
    limiter._check_count = SWEEP_EVERY - 1
    limiter.check("login", "live", limit=100, window_seconds=window, now=later)

    assert list(limiter._events.keys()) == [("login", "live")]
