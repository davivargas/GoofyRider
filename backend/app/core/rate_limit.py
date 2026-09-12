"""Sliding-window rate limiter kept in process memory.

Good enough for a single backend instance. Swap the implementation behind
`RateLimiterProtocol` (for example Redis) when running more than one.
"""

from collections import deque
from dataclasses import dataclass
import math
import threading
from typing import Protocol


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int


class RateLimiterProtocol(Protocol):
    def check(
        self,
        bucket: str,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float,
    ) -> RateLimitDecision: ...


SWEEP_EVERY = 1000


class InMemoryRateLimiter:
    def __init__(self) -> None:
        self._events: dict[tuple[str, str], deque[float]] = {}
        self._lock = threading.Lock()
        self._check_count = 0

    def check(
        self,
        bucket: str,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float,
    ) -> RateLimitDecision:
        with self._lock:
            events = self._events.setdefault((bucket, key), deque())
            cutoff = now - window_seconds
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= limit:
                retry_after = math.ceil(events[0] + window_seconds - now)
                decision = RateLimitDecision(allowed=False, retry_after_seconds=max(retry_after, 1))
            else:
                events.append(now)
                decision = RateLimitDecision(allowed=True, retry_after_seconds=0)

            self._check_count += 1
            if self._check_count >= SWEEP_EVERY:
                self._check_count = 0
                self._sweep(now=now, window_seconds=window_seconds)

            return decision

    def _sweep(self, *, now: float, window_seconds: int) -> None:
        # O(n) pass over every tracked (bucket, key) so the map does not grow
        # without bound when many distinct keys (e.g. attacker IPs) are seen
        # once and never again. Uses the current call's window as the
        # staleness bound, which is the same window every caller of a given
        # bucket passes.
        cutoff = now - window_seconds
        stale_keys = [
            map_key for map_key, events in self._events.items() if not events or events[-1] < cutoff
        ]
        for map_key in stale_keys:
            del self._events[map_key]
