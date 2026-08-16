"""What the phone saw, for the part of a request the backend never hears.

A spoken request that fails on the phone makes no HTTP call at all, so the
most useful thing about it — that it happened — is an absence in the server's
telemetry. This turns that absence into a row.

One event per attempt, flat and wide, in the same shape as the `command` span
so the two can be read together. When the app sends a `traceparent` header
(it does, on this and on `POST /command`), both land in one trace and a single
spoken request reads as a single story.
"""

import logging
from typing import Annotated

import logfire
from fastapi import APIRouter, Depends, HTTPException

from audioreader.auth.dependencies import get_current_user
from audioreader.config import settings
from audioreader.models import User
from audioreader.ratelimit import SlidingWindow
from audioreader.schemas import VoiceAttemptEvent

logger = logging.getLogger(__name__)

router = APIRouter(tags=["events"])

CurrentUser = Annotated[User, Depends(get_current_user)]

#: Telemetry must never be the thing that takes the service down, and a client
#: stuck in a retry loop is the likeliest way it could. Generous next to the
#: command limits — one event per attempt plus a queue drained after an outage
#: is still a small number — but bounded.
_limit = SlidingWindow(settings.event_rate_limit_per_minute, window_seconds=60)


def check_rate_limit(user: CurrentUser) -> None:
    if _limit.limit <= 0:
        return
    if not _limit.check(str(user.id)).allowed:
        logger.warning("event rate limited user %s", user.id)
        raise HTTPException(status_code=429, detail="too many events")
    _limit.prune()


@router.post("/events/voice", status_code=204, dependencies=[Depends(check_rate_limit)])
async def voice_attempt(event: VoiceAttemptEvent, user: CurrentUser) -> None:
    """Record one spoken attempt as the phone experienced it.

    Emitted as a log record rather than a span because the attempt is already
    over: a span would have to invent a duration, and the real one is here as
    an attribute. `exclude_none` keeps the row to what the phone actually
    knew — an absent field and a false one mean different things, and only one
    of them is worth storing.
    """
    logfire.info(
        "voice_attempt",
        user_id=str(user.id),
        **event.model_dump(exclude_none=True),
    )
