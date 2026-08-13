import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth.dependencies import get_current_user
from audioreader.commands import service
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.llm.client import LLMClient, LLMError
from audioreader.llm.provider import get_discovery_llm_client, get_llm_client
from audioreader.models import User
from audioreader.ratelimit import SlidingWindow
from audioreader.routers.feeds import episodes_read
from audioreader.schemas import CommandRequest, CommandResponse

logger = logging.getLogger(__name__)

router = APIRouter(tags=["commands"])

Session = Annotated[AsyncSession, Depends(get_session)]
LLM = Annotated[LLMClient, Depends(get_llm_client)]
DiscoveryLLM = Annotated[LLMClient, Depends(get_discovery_llm_client)]
CurrentUser = Annotated[User, Depends(get_current_user)]

# Even failures must give the app something to say: an error tone alone tells
# a blind user nothing about what went wrong or what to do next.
OUTAGE_RESPONSE = "Sorry, I cannot reach my assistant right now. Please try again in a moment."

_burst_limit = SlidingWindow(settings.command_rate_limit_per_minute, window_seconds=60)
_daily_limit = SlidingWindow(settings.command_rate_limit_per_day, window_seconds=86400)


def check_rate_limit(user: CurrentUser) -> None:
    """Reject a command that would exceed this account's budget.

    The spoken sentence says to wait rather than naming a limit: "you have
    used 12 of 12 requests this minute" is not something to hear when what you
    wanted was a podcast.
    """
    for window, spoken in (
        (_burst_limit, "You are asking a bit faster than I can keep up. Please try again shortly."),
        (_daily_limit, "You have asked for a lot today. Please try again tomorrow."),
    ):
        if window.limit <= 0:
            continue
        decision = window.check(str(user.id))
        if not decision.allowed:
            logger.warning("rate limited user %s (window=%ss)", user.id, window.window_seconds)
            raise HTTPException(
                status_code=429,
                detail={"spoken_response": spoken},
                headers={"Retry-After": str(decision.retry_after)},
            )
    _burst_limit.prune()
    _daily_limit.prune()


@router.post("/command", dependencies=[Depends(check_rate_limit)])
async def command(
    body: CommandRequest, session: Session, llm: LLM, discovery_llm: DiscoveryLLM, user: CurrentUser
) -> CommandResponse:
    try:
        result = await service.interpret(
            session, llm, transcript=body.transcript, user=user, discovery_llm=discovery_llm
        )
    except LLMError as exc:
        raise HTTPException(
            status_code=503,
            detail={"spoken_response": OUTAGE_RESPONSE, "error": str(exc)},
        ) from exc

    episode = None
    if result.episode is not None:
        episode = (await episodes_read(session, user, [result.episode]))[0]

    return CommandResponse(
        action=result.action.value,
        spoken_response=result.spoken_response,
        episode=episode,
        speed=result.speed,
    )
