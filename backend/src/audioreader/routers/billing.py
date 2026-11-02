"""Native purchase synchronization and authenticated RevenueCat notifications."""

import hmac
import json

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import select

from audioreader import billing
from audioreader.config import settings
from audioreader.models import BillingCustomer, User
from audioreader.ratelimit import SlidingWindow
from audioreader.routers.feeds import CurrentUser, Session


def private_response(response: Response):
    response.headers["Cache-Control"] = "private, no-store"


router = APIRouter(prefix="/billing", tags=["billing"], dependencies=[Depends(private_response)])


@router.get("/status")
async def status(session: Session, user: CurrentUser):
    return await billing.status(session, user)


_sync_limit = SlidingWindow(10, window_seconds=60)


def sync_limit(user: CurrentUser):
    decision = _sync_limit.check(str(user.id))
    if not decision.allowed:
        raise HTTPException(
            429,
            "Please wait a moment before refreshing your subscription.",
            headers={"Retry-After": str(decision.retry_after)},
        )
    _sync_limit.prune()


@router.post("/sync", dependencies=[Depends(sync_limit)])
async def sync(session: Session, user: CurrentUser):
    # Purchases and restores are verified with RevenueCat, never with client claims.
    return await billing.status(session, user, refresh=True)


@router.post("/webhook")
async def webhook(request: Request, session: Session):
    secret = settings.revenuecat_webhook_secret
    if not secret or not hmac.compare_digest(request.headers.get("authorization", "").encode(), secret.encode()):
        raise HTTPException(401, "Invalid webhook authorization")
    raw = bytearray()
    async for chunk in request.stream():
        raw.extend(chunk)
        if len(raw) > 128 * 1024:
            raise HTTPException(413, "Webhook too large")
    try:
        event = json.loads(raw)["event"]
        ids = [event.get("app_user_id"), event.get("original_app_user_id")]
        for key in ("aliases", "transferred_from", "transferred_to"):
            ids.extend(event.get(key) or [])
        ids = [value for value in ids if isinstance(value, str)][:100]
    except ValueError, KeyError, TypeError, AttributeError:
        raise HTTPException(422, "Invalid webhook") from None
    owners = list(await session.scalars(select(BillingCustomer.user_id).where(BillingCustomer.id.in_(ids)).distinct()))
    for owner in sorted(owners):
        user = await session.get(User, owner)
        if user:
            # Refetching makes duplicate and out-of-order notifications harmless.
            await billing.current(session, user, refresh=True)
    await session.commit()
    return {"received": True}
