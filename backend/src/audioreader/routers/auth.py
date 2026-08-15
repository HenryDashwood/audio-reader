import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.auth.apple import (
    AppleRevoker,
    AppleTokenVerifier,
    AppleVerificationError,
    get_revoker,
    get_verifier,
)
from audioreader.auth.dependencies import bearer, get_current_user
from audioreader.db import get_session
from audioreader.models import User
from audioreader.schemas import AppleLoginRequest, AuthResponse, UserRead

logger = logging.getLogger(__name__)

router = APIRouter(tags=["auth"])

Session = Annotated[AsyncSession, Depends(get_session)]
Verifier = Annotated[AppleTokenVerifier, Depends(get_verifier)]
Revoker = Annotated[AppleRevoker | None, Depends(get_revoker)]
CurrentUser = Annotated[User, Depends(get_current_user)]


@router.post("/auth/apple")
async def apple_login(body: AppleLoginRequest, session: Session, verifier: Verifier, revoker: Revoker) -> AuthResponse:
    try:
        identity = await verifier.verify(body.identity_token)
    except AppleVerificationError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    # Trade the one-time code for something we can revoke later. It expires
    # within minutes, so it is now or never — but never is survivable, and a
    # failed exchange must not cost her the sign-in.
    refresh_token = None
    if revoker is not None and body.authorization_code:
        refresh_token = await revoker.exchange_code(body.authorization_code)
        if refresh_token is None:
            logger.warning("no refresh token obtained; this account cannot be revoked with Apple")

    user, token = await service.login(session, identity, refresh_token=refresh_token)
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


@router.delete("/me", status_code=204)
async def delete_me(session: Session, user: CurrentUser, revoker: Revoker) -> None:
    """Erase the account. Required by App Store guideline 5.1.1(v), which is
    why this exists as an endpoint rather than a support-email request.

    Apple is told first, because the tokens live in rows that are about to be
    deleted — but only told. If the deployment holds no Apple key, or Apple is
    unreachable, or the sign-in that created this account predates us keeping a
    token, the deletion goes ahead regardless. Erasing her data is the promise;
    reporting it upstream is courtesy, and courtesy does not get a veto.
    """
    if revoker is not None:
        for refresh_token in await service.provider_refresh_tokens(session, user):
            if not await revoker.revoke(refresh_token):
                logger.warning("could not revoke an Apple grant; deleting the account anyway")

    await service.delete_user(session, user)
