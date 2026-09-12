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

    assert limiter.check("login", "k", limit=1, window_seconds=10, now=9.99).retry_after_seconds == 1
