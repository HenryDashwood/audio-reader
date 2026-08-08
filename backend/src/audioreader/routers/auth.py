from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.auth.apple import AppleTokenVerifier, AppleVerificationError, get_verifier
from audioreader.auth.dependencies import bearer, get_current_user
from audioreader.db import get_session
from audioreader.models import User
from audioreader.schemas import AppleLoginRequest, AuthResponse, UserRead

router = APIRouter(tags=["auth"])

Session = Annotated[AsyncSession, Depends(get_session)]
Verifier = Annotated[AppleTokenVerifier, Depends(get_verifier)]
CurrentUser = Annotated[User, Depends(get_current_user)]


@router.post("/auth/apple")
async def apple_login(
    body: AppleLoginRequest, session: Session, verifier: Verifier
) -> AuthResponse:
    try:
        identity = await verifier.verify(body.identity_token)
    except AppleVerificationError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    user, token = await service.login(session, identity)
    return AuthResponse(token=token, user=UserRead.model_validate(user))


@router.post("/auth/logout", status_code=204)
async def logout(
    session: Session,
    _user: CurrentUser,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> None:
    # CurrentUser has already established the token is valid; revoke exactly it.
    if credentials is not None:
        await service.revoke(session, credentials.credentials)


@router.get("/me")
async def me(user: CurrentUser) -> UserRead:
    """Cheap session probe: the app calls this at launch to notice a revoked
    or stale token before the user tries anything else."""
    return UserRead.model_validate(user)
