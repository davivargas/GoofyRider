from collections.abc import Awaitable
from collections.abc import Callable

from fastapi import FastAPI
from fastapi import Request
from fastapi import status
from fastapi.responses import JSONResponse
from fastapi.responses import Response

from app.services.exceptions import AuthenticationError
from app.services.exceptions import ConflictError
from app.services.exceptions import NotFoundError
from app.services.exceptions import ServiceError
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError


def _service_error_handler(
    status_code: int,
) -> Callable[[Request, Exception], Awaitable[Response]]:
    async def handler(_: Request, exc: Exception) -> Response:
        assert isinstance(exc, ServiceError)
        return JSONResponse(
            status_code=status_code,
            content={"detail": str(exc)},
        )

    return handler


def register_service_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(
        AuthenticationError,
        _service_error_handler(status.HTTP_401_UNAUTHORIZED),
    )
    app.add_exception_handler(
        ConflictError,
        _service_error_handler(status.HTTP_409_CONFLICT),
    )
    app.add_exception_handler(
        NotFoundError,
        _service_error_handler(status.HTTP_404_NOT_FOUND),
    )
    app.add_exception_handler(
        ValidationError,
        _service_error_handler(status.HTTP_400_BAD_REQUEST),
    )
    app.add_exception_handler(
        ServiceUnavailableError,
        _service_error_handler(status.HTTP_503_SERVICE_UNAVAILABLE),
    )
