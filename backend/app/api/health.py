from fastapi import APIRouter

router = APIRouter()


@router.get("/health", tags=["health"])
async def health_check() -> dict[str, str]:
    """
    Basic health endpoint to verify that the API is running.
    """
    return {"status": "ok"}