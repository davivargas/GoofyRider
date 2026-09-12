import time

from fastapi import Depends
from fastapi import Request

from app.core.config import get_settings
from app.core.rate_limit import InMemoryRateLimiter
from app.core.rate_limit import RateLimiterProtocol
from app.schemas.auth import LoginRequest
from app.services.exceptions import RateLimitedError

_limiter: InMemoryRateLimiter | None = None


def get_rate_limiter() -> RateLimiterProtocol:
    global _limiter
    if _limiter is None:
        _limiter = InMemoryRateLimiter()
    return _limiter


def client_ip(request: Request) -> str:
    if get_settings().trust_proxy_headers:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return request.client.host if request.client is not None else "unknown"


def enforce_rate_limit(
    limiter: RateLimiterProtocol,
    bucket: str,
    key: str,
    *,
    limit: int,
    window_seconds: int,
) -> None:
    if not get_settings().rate_limit_enabled:
        return
    decision = limiter.check(
        bucket, key, limit=limit, window_seconds=window_seconds, now=time.monotonic()
    )
    if not decision.allowed:
        raise RateLimitedError(decision.retry_after_seconds)


def limit_login(
    request: Request,
    payload: LoginRequest,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> LoginRequest:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "login_ip",
        client_ip(request),
        limit=settings.rate_limit_login_per_ip,
        window_seconds=settings.rate_limit_window_seconds,
    )
    enforce_rate_limit(
        limiter,
        "login_email",
        payload.email,
        limit=settings.rate_limit_login_per_email,
        window_seconds=settings.rate_limit_window_seconds,
    )
    return payload


def limit_register(
    request: Request,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> None:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "register_ip",
        client_ip(request),
        limit=settings.rate_limit_register_per_ip,
        window_seconds=settings.rate_limit_register_window_seconds,
    )


def limit_refresh(
    request: Request,
    limiter: RateLimiterProtocol = Depends(get_rate_limiter),
) -> None:
    settings = get_settings()
    enforce_rate_limit(
        limiter,
        "refresh_ip",
        client_ip(request),
        limit=settings.rate_limit_refresh_per_ip,
        window_seconds=settings.rate_limit_window_seconds,
    )
