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


class InMemoryRateLimiter:
    def __init__(self) -> None:
        self._events: dict[tuple[str, str], deque[float]] = {}
        self._lock = threading.Lock()

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
                return RateLimitDecision(allowed=False, retry_after_seconds=max(retry_after, 1))
            events.append(now)
            return RateLimitDecision(allowed=True, retry_after_seconds=0)
