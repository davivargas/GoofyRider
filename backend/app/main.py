from fastapi import FastAPI

from app.api.health import router as health_router
from app.api.router import api_router

app = FastAPI(
    title="GoofyRider API",
    version="0.1.0",
    description="Backend API for the GoofyRider snowboarding tracker.",
)

app.include_router(health_router)
app.include_router(api_router)


@app.get("/", tags=["root"])
async def root() -> dict[str, str]:
    """
    Simple root endpoint for quick browser verification.
    """
    return {"message": "GoofyRider API is running"}
