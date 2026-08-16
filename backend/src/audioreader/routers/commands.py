import logging
from typing import Annotated

import logfire
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
from audioreader.settings_types import LLMProvider

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
    # One span per spoken request, carrying enough to answer the question the
    # HTTP status code cannot: did we do what she asked? Every command returns
    # 200 whether it played the right episode, the wrong one, or gave up, so
    # correctness has to be reconstructed from these attributes afterwards.
    #
    # There is no label here for "correct" — nothing in the request knows that.
    # What there is: the outcome, and every point at which the pipeline settled
    # for something less than an answer. `action=unknown` is the model saying
    # so outright; the `failure` attribute, set from inside `service.interpret`,
    # names the quieter ways a request ends up going nowhere.
    with logfire.span(
        "command",
        user_id=str(user.id),
        provider=settings.llm_provider.value,
        model=settings.openrouter_model if settings.llm_provider is LLMProvider.OPENROUTER else settings.llm_model,
        # Placeholders: set below once known, so that a command which raises
        # still leaves an attribute saying so rather than an absent key.
        action="error",
        episode_id=None,
    ) as span:
        if settings.telemetry_transcripts:
            span.set_attribute("transcript", body.transcript)

        try:
            result = await service.interpret(
                session, llm, transcript=body.transcript, user=user, discovery_llm=discovery_llm
            )
        except LLMError as exc:
            raise HTTPException(
                status_code=503,
                detail={"spoken_response": OUTAGE_RESPONSE, "error": str(exc)},
            ) from exc

        span.set_attribute("action", result.action.value)

        episode = None
        if result.episode is not None:
            # The title as well as the id: a query about what she is being
            # given should be readable without joining back to the database,
            # which by then may not still hold the row.
            span.set_attribute("episode_id", result.episode.id)
            span.set_attribute("episode_title", result.episode.title)
            episode = (await episodes_read(session, user, [result.episode]))[0]

        return CommandResponse(
            action=result.action.value,
            spoken_response=result.spoken_response,
            episode=episode,
            speed=result.speed,
        )
