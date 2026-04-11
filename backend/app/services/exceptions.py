class ServiceError(Exception):
    """Base class for application service errors."""


class AuthenticationError(ServiceError):
    pass


class ConflictError(ServiceError):
    pass


class NotFoundError(ServiceError):
    pass


class ValidationError(ServiceError):
    pass


class ServiceUnavailableError(ServiceError):
    pass
