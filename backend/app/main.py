from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.exception_handlers import register_service_exception_handlers
from app.api.health import router as health_router
from app.api.router import api_router
from app.core.config import get_settings
from app.services.resort_sync_scheduler import ResortSyncScheduler


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    scheduler = ResortSyncScheduler(
        enabled=settings.resort_sync_enabled,
        interval_days=settings.resort_sync_interval_days,
    )
    scheduler.start()
    try:
        yield
    finally:
        await scheduler.stop()


def create_app() -> FastAPI:
    settings = get_settings()
    application = FastAPI(
        title="GoofyRider API",
        version="0.1.0",
        description="Backend API for the GoofyRider snowboarding tracker.",
        lifespan=lifespan,
        docs_url="/docs" if settings.debug else None,
        redoc_url="/redoc" if settings.debug else None,
        openapi_url="/openapi.json" if settings.debug else None,
    )
    register_service_exception_handlers(application)
    application.include_router(health_router)
    application.include_router(api_router)

    @application.get("/", include_in_schema=False)
    async def root() -> dict[str, str]:
        return {"message": "GoofyRider API is running"}

    return application


app = create_app()
