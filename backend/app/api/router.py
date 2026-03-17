from fastapi import APIRouter

from app.api.auth import router as auth_router
from app.api.resorts import router as resorts_router
from app.api.sessions import router as sessions_router
from app.api.users import router as users_router

api_router = APIRouter(prefix="/v1")
api_router.include_router(auth_router)
api_router.include_router(resorts_router)
api_router.include_router(sessions_router)
api_router.include_router(users_router)
