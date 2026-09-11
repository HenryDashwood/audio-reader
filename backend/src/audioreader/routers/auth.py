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
from audioreader.auth.google import GoogleTokenVerifier, GoogleVerificationError, get_google_verifier
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.models import User, utcnow
from audioreader.schemas import (
    AIDataSharingConsentUpdate,
    AppleLoginRequest,
    AuthResponse,
    GoogleLoginRequest,
    LinkedIdentitiesRead,
    UserRead,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["auth"])

Session = Annotated[AsyncSession, Depends(get_session)]
Verifier = Annotated[AppleTokenVerifier, Depends(get_verifier)]
Revoker = Annotated[AppleRevoker | None, Depends(get_revoker)]
CurrentUser = Annotated[User, Depends(get_current_user)]
GoogleVerifier = Annotated[GoogleTokenVerifier, Depends(get_google_verifier)]

# Increment this whenever the consent screen's description of the data or the
# receiving providers changes materially. Existing permission then stops being
# sufficient until the user sees and accepts the new wording.
AI_DATA_SHARING_CONSENT_VERSION = 3


def has_current_ai_data_sharing_consent(user: User) -> bool:
    """Whether this account accepted the current description of AI use."""

    return (
        user.ai_data_sharing_consented_at is not None
        and user.ai_data_sharing_withdrawn_at is None
        and user.ai_consent_version == AI_DATA_SHARING_CONSENT_VERSION
    )


def user_read(user: User) -> UserRead:
    return UserRead(
        id=user.id,
        display_name=user.display_name,
        ai_data_sharing_consented=has_current_ai_data_sharing_consent(user),
    )


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
    return AuthResponse(token=token, user=user_read(user))


@router.post("/auth/logout", status_code=204)
async def logout(
    session: Session,
    _user: CurrentUser,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> None:
    # CurrentUser has already established the token is valid; revoke exactly it.
    if credentials is not None:
        await service.revoke(session, credentials.credentials)


async def verified_google(body: GoogleLoginRequest, verifier: GoogleTokenVerifier, failure_status: int = 401):
    if not settings.google_client_id:
        raise HTTPException(status_code=503, detail={"spoken_response": "Google sign-in is not available yet."})
    try:
        return await verifier.verify(body.identity_token)
    except GoogleVerificationError as exc:
        raise HTTPException(
            status_code=failure_status,
            detail={"spoken_response": "Google sign-in could not be verified. Please try again."},
        ) from exc


@router.post("/auth/google", response_model=AuthResponse)
async def google_login(body: GoogleLoginRequest, session: Session, verifier: GoogleVerifier) -> AuthResponse:
    identity = await verified_google(body, verifier)
    user, token = await service.login(session, identity, provider="google")
    return AuthResponse(token=token, user=user_read(user))


@router.get("/me/identities", response_model=LinkedIdentitiesRead)
async def linked_identities(session: Session, user: CurrentUser) -> LinkedIdentitiesRead:
    return LinkedIdentitiesRead(providers=await service.identity_providers(session, user))


@router.post("/me/identities/google", response_model=LinkedIdentitiesRead)
async def link_google(
    body: GoogleLoginRequest, session: Session, user: CurrentUser, verifier: GoogleVerifier
) -> LinkedIdentitiesRead:
    identity = await verified_google(body, verifier, failure_status=400)
    try:
        await service.link_identity(session, user, identity, "google")
    except service.IdentityAlreadyLinked as exc:
        raise HTTPException(status_code=409, detail={"spoken_response": str(exc)}) from exc
    return await linked_identities(session, user)


@router.post("/me/identities/apple", response_model=LinkedIdentitiesRead)
async def link_apple(
    body: AppleLoginRequest, session: Session, user: CurrentUser, verifier: Verifier, revoker: Revoker
) -> LinkedIdentitiesRead:
    try:
        identity = await verifier.verify(body.identity_token)
    except AppleVerificationError as exc:
        raise HTTPException(
            status_code=400, detail={"spoken_response": "Apple sign-in could not be verified. Please try again."}
        ) from exc
    refresh_token = (
        await revoker.exchange_code(body.authorization_code) if revoker and body.authorization_code else None
    )
    try:
        await service.link_identity(session, user, identity, "apple", refresh_token)
    except service.IdentityAlreadyLinked as exc:
        raise HTTPException(status_code=409, detail={"spoken_response": str(exc)}) from exc
    return await linked_identities(session, user)


@router.get("/me")
async def me(user: CurrentUser) -> UserRead:
    """Cheap session probe: the app calls this at launch to notice a revoked
    or stale token before the user tries anything else."""
    return user_read(user)


@router.put("/me/ai-data-sharing", response_model=UserRead)
async def set_ai_data_sharing(body: AIDataSharingConsentUpdate, session: Session, user: CurrentUser) -> UserRead:
    """Record or withdraw the explicit choice made in the app.

    Revocation takes effect before the response: /command checks these fields
    on every request, so there is no cache or propagation window in which a
    withdrawn choice can still reach the AI provider.
    """
    if body.granted:
        user.ai_consent_version = AI_DATA_SHARING_CONSENT_VERSION
        user.ai_data_sharing_consented_at = utcnow()
        user.ai_data_sharing_withdrawn_at = None
    else:
        # Keep the version and timestamps until account deletion as the audit
        # record of what was accepted and when it was withdrawn. The command
        # gate checks withdrawn_at, so this does not preserve permission.
        user.ai_data_sharing_withdrawn_at = utcnow()
    await session.commit()
    return user_read(user)


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
    if revoker is not None and settings.apple_revoke_on_account_deletion:
        from audioreader.routers.apple_browser import web_revoker

        for client_id, refresh_token in await service.apple_refresh_grants(session, user):
            grant_revoker = revoker if client_id == settings.apple_bundle_id else web_revoker(client_id)
            if grant_revoker is None or not await grant_revoker.revoke(refresh_token):
                logger.warning("could not revoke an Apple grant; deleting the account anyway")

    await service.delete_user(session, user)
