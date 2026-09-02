"""Where the mail-receiving Worker delivers each email.

Not a user endpoint: the caller is the Worker at the inbound domain, and it
proves itself with an HMAC over the bytes rather than a bearer token. The
status codes are chosen for that caller — a 404 tells it to bounce the
message as undeliverable, a 202 that the message is ours now and must not
be retried, and anything else that it should let the sender try again.
"""

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.db import get_session
from audioreader.newsletters import service
from audioreader.schemas import InboundReceipt

logger = logging.getLogger(__name__)

router = APIRouter(tags=["inbound"])

Session = Annotated[AsyncSession, Depends(get_session)]


@router.post("/inbound/email", status_code=202)
async def receive_email(
    request: Request,
    session: Session,
    x_magpie_signature: Annotated[str | None, Header()] = None,
    x_magpie_recipient: Annotated[str | None, Header()] = None,
) -> InboundReceipt:
    if not settings.inbound_email_enabled:
        raise HTTPException(status_code=503, detail="inbound email is not configured")

    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > settings.inbound_email_max_bytes:
        raise HTTPException(status_code=413, detail="message too large")
    raw = await request.body()
    if len(raw) > settings.inbound_email_max_bytes:
        raise HTTPException(status_code=413, detail="message too large")
    if not raw:
        raise HTTPException(status_code=400, detail="empty message")

    if not service.signature_is_valid(raw, x_magpie_signature):
        raise HTTPException(status_code=401, detail="bad signature")

    recipient = x_magpie_recipient or service.recipient_from_headers(raw)
    user = await service.user_for_recipient(session, recipient)
    if user is None:
        raise HTTPException(status_code=404, detail="no such address")

    delivery = await service.receive(session, user, raw)
    logger.info("inbound email for user %s: %s", user.id, delivery.status)
    return InboundReceipt(status=delivery.status, feed_id=delivery.feed_id, episode_id=delivery.episode_id)
