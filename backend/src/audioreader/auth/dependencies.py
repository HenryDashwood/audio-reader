from typing import Annotated

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.db import get_session
from audioreader.models import User

# auto_error=False so a missing header reaches us and gets the speakable 401
# below, instead of FastAPI's own unspoken 403.
bearer = HTTPBearer(auto_error=False)

# The detail shape matches the /command error contract: anything the app might
# surface must be speakable, since the primary user cannot read a toast.
_UNAUTHENTICATED = HTTPException(
    status_code=401,
    detail={"spoken_response": "Please open Hearful and sign in."},
    headers={"WWW-Authenticate": "Bearer"},
)


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> User:
    if credentials is None:
        raise _UNAUTHENTICATED

    user = await service.user_for_token(session, credentials.credentials)
    if user is None:
        raise _UNAUTHENTICATED
    return user
