from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import RedirectResponse

from app.api.exception_handlers import register_service_exception_handlers
from app.api.health import router as health_router
from app.api.router import api_router
from app.core.config import get_resort_sync_enabled
from app.core.config import get_resort_sync_interval_days
from app.services.resort_sync_scheduler import ResortSyncScheduler


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    scheduler = ResortSyncScheduler(
        enabled=get_resort_sync_enabled(),
        interval_days=get_resort_sync_interval_days(),
    )
    scheduler.start()
    try:
        yield
    finally:
        await scheduler.stop()

app = FastAPI(
    title="GoofyRider API",
    version="0.1.0",
    description="Backend API for the GoofyRider snowboarding tracker.",
    lifespan=lifespan,
)

register_service_exception_handlers(app)

app.include_router(health_router)
app.include_router(api_router)


@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse(url="/health")
