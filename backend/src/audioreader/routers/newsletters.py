"""Her newsletter address, and the senders waiting for her answer."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth.dependencies import get_current_user
from audioreader.db import get_session
from audioreader.models import User
from audioreader.newsletters import service
from audioreader.routers.feeds import check_feed_operation_limit, counts_for, to_feed_read
from audioreader.schemas import (
    FeedRead,
    NewsletterAddressRead,
    NewsletterSignupRead,
    NewsletterSignupRequest,
    PendingNewsletterRead,
)

router = APIRouter(prefix="/newsletters", tags=["newsletters"])

Session = Annotated[AsyncSession, Depends(get_session)]
CurrentUser = Annotated[User, Depends(get_current_user)]


@router.get("/address")
async def address(session: Session, user: CurrentUser) -> NewsletterAddressRead:
    """The address to give a newsletter. Minted on first request."""
    try:
        value = await service.inbound_address(session, user)
    except service.NewslettersDisabledError as exc:
        raise HTTPException(
            status_code=503,
            detail={"spoken_response": "Newsletters by email are not available on this server yet."},
        ) from exc
    return NewsletterAddressRead(address=value)


@router.post("/signups", dependencies=[Depends(check_feed_operation_limit)])
async def sign_up(body: NewsletterSignupRequest, session: Session, user: CurrentUser) -> NewsletterSignupRead:
    """Ask a newsletter's site to send its newsletter to her address.

    Whatever happens is a sentence: submitted, or why not and what to do
    instead. A submitted signup shows up as a followed show by itself when
    the newsletter's first email arrives.
    """
    try:
        outcome = await service.sign_up(session, user, str(body.url))
    except service.NewslettersDisabledError as exc:
        raise HTTPException(
            status_code=503,
            detail={"spoken_response": "Newsletters by email are not available on this server yet."},
        ) from exc
    return NewsletterSignupRead(
        status=outcome.status,
        publication=outcome.publication,
        platform=outcome.platform,
        address=outcome.address,
        reason=outcome.reason,
        spoken_response=outcome.spoken_response,
    )


@router.get("/pending")
async def pending(session: Session, user: CurrentUser) -> list[PendingNewsletterRead]:
    """Senders that have written to her address and are waiting for a yes or no."""
    return [
        PendingNewsletterRead(
            id=item.feed.id,
            title=item.feed.title,
            sender_address=item.feed.description or "",
            message_count=item.message_count,
            latest_title=item.latest_title,
            latest_at=item.latest_at,
        )
        for item in await service.pending_senders(session, user)
    ]


@router.post("/{feed_id}/approve")
async def approve(feed_id: int, session: Session, user: CurrentUser) -> FeedRead:
    feed = await service.approve(session, user, feed_id)
    if feed is None:
        raise HTTPException(status_code=404, detail="no such newsletter")
    count, audio_count = await counts_for(session, feed.id)
    return to_feed_read(feed, episode_count=count, audio_count=audio_count)


@router.post("/{feed_id}/block", status_code=204)
async def block(feed_id: int, session: Session, user: CurrentUser) -> None:
    if not await service.block(session, user, feed_id):
        raise HTTPException(status_code=404, detail="no such newsletter")
