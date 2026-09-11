"""Apple's browser callback never carries a Magpie session back through a URL.

A short-lived, database-backed handoff binds Apple's nonce to the initiating
app's SHA-256 proof and (for linking) the exact live Magpie session.
"""

import base64
import hashlib
import secrets
from datetime import timedelta
from typing import Annotated, Literal
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx
from cryptography.fernet import Fernet
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy import delete, update
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import secrets_store
from audioreader.auth import service
from audioreader.auth.apple import AppleRevoker, AppleTokenVerifier, AppleVerificationError
from audioreader.auth.dependencies import bearer
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.models import AppleBrowserFlow, utcnow
from audioreader.routers.auth import user_read
from audioreader.schemas import AuthResponse


def no_store(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"


router = APIRouter(tags=["auth"], dependencies=[Depends(no_store)])
Session = Annotated[AsyncSession, Depends(get_session)]
Credentials = Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]
TTL_SECONDS = 300
RETURN_SCHEMES = Literal["com.henrydashwood.magpie.auth", "com.henrydashwood.magpie.dev.auth"]


class BrowserStart(BaseModel):
    challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    purpose: Literal["login", "link"]
    return_scheme: RETURN_SCHEMES


class BrowserStarted(BaseModel):
    state: str
    authorization_url: str
    expires_in: int = TTL_SECONDS


class BrowserProof(BaseModel):
    state: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    verifier: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")


class BrowserResult(BaseModel):
    status: Literal["pending", "cancelled", "complete"]
    auth: AuthResponse | None = None
    providers: list[str] | None = None


def fail(message: str, status: int = 400) -> HTTPException:
    return HTTPException(status_code=status, detail={"spoken_response": message})


def web_revoker(client_id: str | None = None) -> AppleRevoker | None:
    if not settings.apple_revocation_configured:
        return None
    return AppleRevoker(
        client_id=client_id or settings.apple_services_id,
        team_id=settings.apple_team_id,
        key_id=settings.apple_key_id,
        private_key=settings.apple_private_key,
        token_url=settings.apple_token_url,
        revoke_url=settings.apple_revoke_url,
    )


def require_configuration() -> AppleRevoker:
    uri = urlsplit(settings.apple_browser_redirect_uri)
    revoker = web_revoker()
    try:
        # Browser codes must never fall through the legacy plaintext fallback.
        Fernet(settings.apple_token_encryption_key.encode())
        valid = (
            settings.apple_services_id
            and settings.apple_services_id != settings.apple_bundle_id
            and revoker is not None
            and uri.scheme == "https"
            and uri.hostname
            and not uri.username
            and not uri.query
            and not uri.fragment
            and uri.path == "/auth/apple/browser/callback"
        )
    except (ValueError, TypeError):
        valid = False
    if not valid or revoker is None:
        raise fail("Apple sign-in is not available on Android yet. Please try again later.", 503)
    return revoker


def proof_challenge(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


@router.post("/auth/apple/browser/start", response_model=BrowserStarted)
async def start(body: BrowserStart, session: Session, credentials: Credentials) -> BrowserStarted:
    require_configuration()
    user = None
    session_hash = None
    if body.purpose == "link":
        user = await service.user_for_token(session, credentials.credentials) if credentials else None
        if user is None:
            raise fail("Please sign in before connecting Apple.", 401)
        session_hash = service.hash_token(credentials.credentials) if credentials else None
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)
    # Expired callbacks/proofs cannot be used; also reclaim abandoned flows.
    await session.execute(delete(AppleBrowserFlow).where(AppleBrowserFlow.expires_at <= utcnow()))
    session.add(
        AppleBrowserFlow(
            state_hash=service.hash_token(state),
            challenge=body.challenge,
            nonce=nonce,
            return_scheme=body.return_scheme,
            user_id=user.id if user else None,
            session_hash=session_hash,
            expires_at=utcnow() + timedelta(seconds=TTL_SECONDS),
        )
    )
    await session.commit()
    query = urlencode(
        {
            "client_id": settings.apple_services_id,
            "redirect_uri": settings.apple_browser_redirect_uri,
            "response_type": "code",
            "response_mode": "form_post",
            "scope": "email",
            "state": state,
            "nonce": nonce,
        }
    )
    return BrowserStarted(state=state, authorization_url="https://appleid.apple.com/auth/authorize?" + query)


def callback_page(scheme: str | None, status_code: int = 200) -> HTMLResponse:
    message = (
        "Return to Magpie to finish signing in."
        if scheme
        else "This sign-in has expired. Return to Magpie and try again."
    )
    link = f'<p><a href="{scheme}://apple-sign-in">Return to Magpie</a></p>' if scheme else ""
    # Only the fixed allowlisted scheme is included. No provider code, state,
    # identity, bearer token, script, or external resource appears in this page.
    return HTMLResponse(
        '<!doctype html><html lang="en"><meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>Magpie sign-in</title><body><h1>Magpie</h1><p>{message}</p>{link}</body></html>",
        status_code=status_code,
        headers={
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
        },
    )


@router.post("/auth/apple/browser/callback", include_in_schema=False)
async def callback(request: Request, session: Session) -> HTMLResponse:
    require_configuration()
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/x-www-form-urlencoded":
        return callback_page(None, 400)
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > 16384:
            return callback_page(None, 413)
    try:
        fields = parse_qs(data.decode(), keep_blank_values=True, max_num_fields=8)
        if any(len(values) != 1 for values in fields.values()):
            return callback_page(None, 400)
    except (UnicodeError, ValueError):
        return callback_page(None, 400)
    state = fields.get("state", [""])[0]
    if len(state) != 43:
        return callback_page(None, 400)
    flow = await session.get(AppleBrowserFlow, service.hash_token(state))
    if flow is None or service._as_aware(flow.expires_at) <= utcnow():
        return callback_page(None, 400)
    code = fields.get("code", [""])[0]
    error = fields.get("error", [""])[0]
    outcome = "cancelled" if error == "user_cancelled_authorize" else "failed"
    if code and len(code) <= 4096 and not error:
        outcome = "ready"
    await session.execute(
        update(AppleBrowserFlow)
        .where(
            AppleBrowserFlow.state_hash == flow.state_hash,
            AppleBrowserFlow.outcome.is_(None),
        )
        .values(outcome=outcome, authorization_code=secrets_store.encrypt(code) if outcome == "ready" else None)
    )
    await session.commit()
    return callback_page(flow.return_scheme)


async def matching_flow(body: BrowserProof, session: AsyncSession) -> AppleBrowserFlow:
    flow = await session.get(AppleBrowserFlow, service.hash_token(body.state))
    if flow is None or service._as_aware(flow.expires_at) <= utcnow():
        raise fail("This Apple sign-in has expired. Please try again.", 410)
    if not secrets.compare_digest(flow.challenge, proof_challenge(body.verifier)):
        raise fail("This Apple sign-in could not be verified.")
    return flow


@router.post("/auth/apple/browser/cancel", status_code=204)
async def cancel(body: BrowserProof, session: Session) -> None:
    flow = await matching_flow(body, session)
    await session.execute(delete(AppleBrowserFlow).where(AppleBrowserFlow.state_hash == flow.state_hash))
    await session.commit()


@router.post("/auth/apple/browser/complete", response_model=BrowserResult)
async def complete(body: BrowserProof, session: Session, credentials: Credentials) -> BrowserResult:
    revoker = require_configuration()
    flow = await matching_flow(body, session)
    user = None
    if flow.user_id is not None:
        if credentials is None or service.hash_token(credentials.credentials) != flow.session_hash:
            raise fail("Return to the account where you started connecting Apple.", 403)
        user = await service.user_for_token(session, credentials.credentials)
        if user is None or user.id != flow.user_id:
            raise fail("Please sign in again before connecting Apple.", 401)
    if flow.outcome is None:
        return BrowserResult(status="pending")
    # Claim once across backend workers, before any external code exchange.
    # A lost response requires a fresh attempt, never a replayable session URL.
    code, nonce, outcome = secrets_store.decrypt(flow.authorization_code), flow.nonce, flow.outcome
    claimed = await session.scalar(
        delete(AppleBrowserFlow)
        .where(
            AppleBrowserFlow.state_hash == flow.state_hash,
            AppleBrowserFlow.outcome.is_not(None),
        )
        .returning(AppleBrowserFlow.state_hash)
    )
    await session.commit()
    if claimed is None:
        raise fail("This Apple sign-in has already finished. Please try again.", 410)
    if outcome == "cancelled":
        return BrowserResult(status="cancelled")
    if outcome != "ready" or not code:
        raise fail("Apple sign-in did not finish. Please try again.")
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                settings.apple_token_url,
                data={
                    "client_id": settings.apple_services_id,
                    "client_secret": revoker.client_secret(),
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": settings.apple_browser_redirect_uri,
                },
            )
            response.raise_for_status()
            payload = response.json()
        identity = await browser_verifier().verify(payload["id_token"], nonce=nonce)
        refresh_token = payload.get("refresh_token")
        if refresh_token is not None and not isinstance(refresh_token, str):
            raise ValueError("invalid refresh token")
    except (httpx.HTTPError, ValueError, KeyError, TypeError, AppleVerificationError) as exc:
        raise fail("Apple sign-in could not be verified. Please try again.") from exc
    if user is not None:
        # The session may have been revoked during Apple's round trip.
        live_user = await service.user_for_token(session, credentials.credentials) if credentials else None
        if live_user is None or live_user.id != user.id:
            raise fail("Please sign in again before connecting Apple.", 401)
        try:
            await service.link_identity(session, user, identity, "apple", refresh_token, settings.apple_services_id)
        except service.IdentityAlreadyLinked as exc:
            raise fail(str(exc), 409) from exc
        return BrowserResult(status="complete", providers=await service.identity_providers(session, user))
    user, token = await service.login(
        session, identity, refresh_token=refresh_token, refresh_token_client_id=settings.apple_services_id
    )
    return BrowserResult(status="complete", auth=AuthResponse(token=token, user=user_read(user)))


_verifier: AppleTokenVerifier | None = None


def browser_verifier() -> AppleTokenVerifier:
    global _verifier
    if (
        _verifier is None
        or _verifier.audience != settings.apple_services_id
        or _verifier.jwks_url != settings.apple_jwks_url
    ):
        _verifier = AppleTokenVerifier(settings.apple_services_id, settings.apple_jwks_url)
    return _verifier
