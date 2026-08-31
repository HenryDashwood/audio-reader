import json
import logging
from collections.abc import AsyncIterator
from typing import Annotated

import logfire
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import telemetry
from audioreader.auth.dependencies import get_current_user
from audioreader.commands import service
from audioreader.commands.conversation import AssistantDelta, ConversationFinished, converse
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.llm.client import LLMClient, LLMError
from audioreader.llm.openai_responses import ResponsesStreamingClient
from audioreader.llm.provider import (
    get_conversation_llm_client,
    get_discovery_llm_client,
    get_llm_client,
)
from audioreader.models import User, utcnow
from audioreader.ratelimit import SlidingWindow
from audioreader.routers.auth import has_current_ai_data_sharing_consent
from audioreader.routers.feeds import episodes_read
from audioreader.schemas import CommandRequest, CommandResponse
from audioreader.settings_types import LLMProvider

logger = logging.getLogger(__name__)

router = APIRouter(tags=["commands"])

Session = Annotated[AsyncSession, Depends(get_session)]
LLM = Annotated[LLMClient, Depends(get_llm_client)]
DiscoveryLLM = Annotated[LLMClient, Depends(get_discovery_llm_client)]
ConversationLLM = Annotated[ResponsesStreamingClient, Depends(get_conversation_llm_client)]
CurrentUser = Annotated[User, Depends(get_current_user)]

# Even failures must give the app something to say: an error tone alone tells
# a blind user nothing about what went wrong or what to do next.
OUTAGE_RESPONSE = "Sorry, I cannot reach my assistant right now. Please try again in a moment."

_burst_limit = SlidingWindow(settings.command_rate_limit_per_minute, window_seconds=60)
_daily_limit = SlidingWindow(settings.command_rate_limit_per_day, window_seconds=86400)


def _model_name() -> str:
    if settings.llm_provider is LLMProvider.OPENROUTER:
        return settings.openrouter_model
    if settings.llm_provider is LLMProvider.OPENAI:
        return settings.openai_model
    return settings.llm_model


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
    # This is deliberately enforced server-side as well as in the app. An old
    # client, a Siri shortcut, or a hand-written request must not be able to
    # send personal data to the model without the recorded current choice.
    if not has_current_ai_data_sharing_consent(user):
        raise HTTPException(
            status_code=403,
            detail={"spoken_response": ("Before using voice commands, open Magpie and allow AI data sharing.")},
        )
    # One wide event per spoken request. Everything the pipeline learns is
    # attached here rather than scattered across log lines, because the
    # question worth asking spans the whole request — "which commands were
    # misunderstood, and what did her library look like when they were?" — and
    # that is a query over one row, not a search through many.
    #
    # It exists because the HTTP status code cannot answer it. Every command
    # returns 200 whether it played the right episode, the wrong one, or gave
    # up. There is no label here for "correct"; nothing in the request knows
    # that. What there is: the outcome, what the model wanted, what it was
    # given to choose from, what it cost, and every point at which the pipeline
    # settled for less than an answer. `action=unknown` is the model saying so
    # outright; the `failure` attribute, set from inside `service.interpret`,
    # names the quieter ways a request ends up going nowhere.
    with (
        logfire.span(
            "command",
            telemetry_id=str(user.telemetry_id),
            provider=settings.llm_provider.value,
            model=_model_name(),
            # How much she actually said. A request that arrives as two or
            # three words is usually the phone cutting her off rather than the
            # model misreading her, and the two are indistinguishable from the
            # outcome alone — this has twice looked like a model failure and
            # been a truncated transcript.
            transcript_words=len(body.transcript.split()),
            # How far into an exchange this is: 0 for a request that starts a
            # subject, higher for an answer to something we asked. The pair to
            # `expects_reply` below, and together they say whether asking her
            # a question actually gets the command carried out — a clarify
            # that is never answered is a dead end with a polite voice, and
            # from a single row it looks exactly like one that worked.
            conversation_turns=len(body.turns),
            # Seeded, then overwritten once known. Both of these are grouped
            # by rather than filtered on, and a missing key and a null make an
            # untidy bucket in a way a plain string does not — so a command
            # that succeeded says `failure=none`, and one that died before it
            # reached an outcome says `action=error` rather than nothing.
            action="error",
            failure="none",
        ) as span,
        telemetry.collect_llm_usage(),
    ):
        if settings.telemetry_transcripts:
            span.set_attribute("transcript", body.transcript)

        try:
            result = await service.interpret(
                session,
                llm,
                transcript=body.transcript,
                user=user,
                discovery_llm=discovery_llm,
                now_playing_episode_id=body.now_playing_episode_id,
                turns=body.turns,
                country=body.country,
            )
        except LLMError as exc:
            raise HTTPException(
                status_code=503,
                detail={"spoken_response": OUTAGE_RESPONSE, "error": str(exc)},
            ) from exc

        span.set_attribute("action", result.action.value)
        span.set_attribute("expects_reply", result.expects_reply)
        if result.speed is not None:
            span.set_attribute("speed", result.speed)

        episode = None
        if result.episode is not None:
            # Titles as well as ids: a query about what she is being given
            # should be readable without joining back to the database, which by
            # then may not still hold the row.
            span.set_attribute("episode_id", result.episode.id)
            span.set_attribute("episode_title", result.episode.title)
            span.set_attribute("feed_title", result.episode.feed.title or "")
            # Whether the answer came out of the recency window or the back
            # catalogue. Feeds carry their whole archive, and reaching an old
            # episode is the thing the candidate search exists to do — this is
            # how you see whether it is working outside the eval corpus.
            if result.episode.published_at is not None:
                age = utcnow() - result.episode.published_at
                span.set_attribute("episode_age_days", age.days)
            episode = (await episodes_read(session, user, [result.episode]))[0]

        return CommandResponse(
            action=result.action.value,
            spoken_response=result.spoken_response,
            episode=episode,
            speed=result.speed,
            expects_reply=result.expects_reply,
        )


@router.post("/command/stream", dependencies=[Depends(check_rate_limit)])
async def command_stream(
    body: CommandRequest,
    session: Session,
    llm: ConversationLLM,
    user: CurrentUser,
) -> StreamingResponse:
    """Stream the model's words while it searches and operates Magpie.

    NDJSON keeps the wire format deliberately small: text deltas arrive as
    complete lines, followed by one ordinary CommandResponse which older app
    logic can handle unchanged.
    """
    if not has_current_ai_data_sharing_consent(user):
        raise HTTPException(
            status_code=403,
            detail={"spoken_response": "Before using voice commands, open Magpie and allow AI data sharing."},
        )

    async def events() -> AsyncIterator[bytes]:
        # StreamingResponse consumes this generator after the route function
        # returns, so the span must live inside it. Otherwise all OpenAI, web,
        # tool and database work becomes a set of unrelated traces and the
        # exact path behind a slow or wrong conversation is invisible.
        with (
            logfire.span(
                "command",
                telemetry_id=str(user.telemetry_id),
                provider=LLMProvider.OPENAI.value,
                model=settings.openai_model,
                pipeline="conversation",
                transcript_words=len(body.transcript.split()),
                conversation_turns=len(body.turns),
                action="error",
                failure="none",
            ) as span,
            telemetry.collect_llm_usage(),
        ):
            if settings.telemetry_transcripts:
                span.set_attribute("transcript", body.transcript)

            try:
                async for event in converse(
                    session,
                    llm,
                    transcript=body.transcript,
                    user=user,
                    now_playing_episode_id=body.now_playing_episode_id,
                    turns=body.turns,
                    country=body.country,
                ):
                    if isinstance(event, AssistantDelta):
                        yield _line({"type": "assistant_delta", "text": event.text})
                        continue
                    if isinstance(event, ConversationFinished):
                        result = event.result
                        span.set_attribute("action", result.action.value)
                        span.set_attribute("expects_reply", result.expects_reply)
                        if settings.telemetry_transcripts:
                            span.set_attribute("assistant_response", result.spoken_response)
                        if result.speed is not None:
                            span.set_attribute("speed", result.speed)

                        episode = None
                        if result.episode is not None:
                            span.set_attribute("episode_id", result.episode.id)
                            span.set_attribute("episode_title", result.episode.title)
                            span.set_attribute("feed_title", result.episode.feed.title or "")
                            episode = (await episodes_read(session, user, [result.episode]))[0]
                        response = CommandResponse(
                            action=result.action.value,
                            spoken_response=result.spoken_response,
                            episode=episode,
                            speed=result.speed,
                            expects_reply=result.expects_reply,
                        )
                        yield _line({"type": "result", "response": response.model_dump(mode="json")})
                        return
            except LLMError as exc:
                span.set_attribute("failure", "llm_error")
                logger.warning("streamed command failed: %s", exc)
                yield _line({"type": "error", "spoken_response": OUTAGE_RESPONSE})

    return StreamingResponse(
        events(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


def _line(value: dict) -> bytes:
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()
