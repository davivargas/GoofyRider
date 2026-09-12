class ServiceError(Exception):
    """Base class for application service errors."""


class AuthenticationError(ServiceError):
    pass


class ConflictError(ServiceError):
    pass


class SessionNotYetCompletedError(ServiceError):
    pass


class NotFoundError(ServiceError):
    pass


class ValidationError(ServiceError):
    pass


class ServiceUnavailableError(ServiceError):
    pass


class RateLimitedError(ServiceError):
    def __init__(self, retry_after_seconds: int) -> None:
        self.retry_after_seconds = retry_after_seconds
        super().__init__(f"Too many requests. Try again in {retry_after_seconds} seconds.")
