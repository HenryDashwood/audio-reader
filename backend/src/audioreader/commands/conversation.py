"""Streamed voice commands with explicit actions, filters and saved clarification choices.

Models interpret language; Python validates targets, performs calendar and
library selection, claims continuations once, and reports verified effects.
"""

import asyncio
import copy
import json
import logging
import re
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Any
from zoneinfo import ZoneInfo

import logfire
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.commands import clarifications, library, selection, service, undo
from audioreader.commands.intents import (
    Action,
    Candidate,
    Clarification,
    CommandStatus,
    InterpretResult,
    Speaker,
    Turn,
)
from audioreader.commands.receipts import check_cancelled
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.discovery import resolve_feed
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, search_podcasts
from audioreader.feeds.service import AlreadySubscribedError
from audioreader.llm.client import LLMError
from audioreader.llm.openai_responses import (
    OpenAIResponsesClient,
    ResponseCompleted,
    ResponsesStreamingClient,
    ResponseTextDelta,
)
from audioreader.models import Episode, Feed, Subscription, User, utcnow
from audioreader.newsletters import service as newsletters
from audioreader.newsletters.service import PendingSender

logger = logging.getLogger(__name__)


INSTRUCTIONS = """You are Magpie, the concise voice interface to a listening app.
Understand the user's intent and use the app tools to carry it out.

The speech transcript is imperfect dictation. Recover overwhelmingly likely
proper nouns and brands from the words, conversation, directory results, and
web results. Transcription may split one brand into ordinary words, omit
punctuation, or choose a common word with the same sound. Do not search only
for the literal transcript when its intended meaning is clear.

Resolve material ambiguity BEFORE taking any action in a compound request.
Prefer completing a request in one turn. Publications can use a custom domain
even when the user calls them a Substack: use web search to identify a named
newsletter, blog, publication, or person's writing, then inspect its real site
to find its feed. Use the podcast directory only for podcasts. Do not invent a
hostname from a person's or publication's name. Do not ask for confirmation
when one candidate is overwhelmingly more likely than the others. Ask one
short clarification only when genuine uncertainty would materially change the
action. A useful clarification names the likely candidate and one short
distinguishing fact.

Never say an action succeeded before calling its action tool. Do not narrate
searches or announce that you are about to use a tool. Call an action tool
without accompanying text; Magpie will immediately confirm the verified tool
result. When you need clarification, reply with one brief question. Use plain
spoken text only: never Markdown, bullets, emoji, or URLs. The user is waiting
through every word.

For playback and filing, use only episode IDs in the supplied library or
returned by load_show_episodes. For unsubscribe, use only a supplied feed ID.

Newsletters arrive by email at the user's private newsletter address. A sender
the user has not yet answered is listed as waiting. approve_newsletter follows
it and block_newsletter refuses it for good, each using only a listed
newsletter ID; when one sender is waiting, "it", "that one" or "the
newsletter" means that sender. read_newsletter_address says the address: call
it when the user asks what address to give a newsletter or where newsletters
should be sent.

When the user asks to follow a newsletter and inspect_publication finds no
feed on its site — a Substack, Ghost, Mailchimp, Buttondown, Kit or beehiiv
newsletter, or any site with an email signup box — call
sign_up_for_newsletter with that site's URL. It submits the user's private
newsletter address, and the newsletter then arrives by email. Never call it
for a podcast, for a site whose feed was found, or with a URL you guessed.
"""


TOOLS: list[dict[str, Any]] = [
    {"type": "web_search"},
    {
        "type": "function",
        "name": "search_podcast_directory",
        "description": (
            "Search the public podcast directory for a podcast. Use this only when the requested "
            "thing is a podcast; do not use it for a newsletter, blog, publication, Substack, "
            "or a person's writing. Returns candidates for you to interpret."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "inspect_publication",
        "description": (
            "Inspect a website or feed URL and return its verified canonical feed and title. "
            "Use a URL supplied by the user or returned by web or podcast search; never guess or "
            "invent a hostname from a name."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "subscribe_to_feed",
        "description": (
            "Subscribe the user to a verified podcast or publication feed URL returned by "
            "inspect_publication or the podcast directory. Never construct or guess the URL."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"feed_url": {"type": "string"}},
            "required": ["feed_url"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "unsubscribe_from_feed",
        "description": "Unsubscribe from one of the user's supplied feed IDs.",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"feed_id": {"type": "integer"}},
            "required": ["feed_id"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "approve_newsletter",
        "description": (
            "Follow a newsletter sender that is waiting for the user's answer, by its listed newsletter ID."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"newsletter_id": {"type": "integer"}},
            "required": ["newsletter_id"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "block_newsletter",
        "description": (
            "Refuse a newsletter sender that is waiting for the user's answer, by its listed newsletter ID. "
            "Its messages are deleted and anything it sends later is dropped."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"newsletter_id": {"type": "integer"}},
            "required": ["newsletter_id"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "sign_up_for_newsletter",
        "description": (
            "Sign the user's private newsletter address up to the newsletter on a website that has no feed. "
            "Use a URL supplied by the user or returned by web search; never guess one."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "read_newsletter_address",
        "description": "Say the user's private newsletter address, the one to give a newsletter when signing up.",
        "strict": True,
        "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
    },
    {
        "type": "function",
        "name": "load_show_episodes",
        "description": (
            "Load a podcast/publication by feed URL without subscribing, and return episodes to choose from."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "feed_url": {"type": "string"},
                "episode_query": {"type": ["string", "null"]},
            },
            "required": ["feed_url", "episode_query"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "play_episode",
        "description": "Play one of the supplied episode IDs.",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"episode_id": {"type": "integer"}},
            "required": ["episode_id"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "set_playback_speed",
        "description": "Set playback speed between 0.5 and 3.0 times normal.",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {"speed": {"type": "number"}},
            "required": ["speed"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "file_episode",
        "description": "Mark an episode played, dismiss it from Latest, or restore it.",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "episode_id": {"type": "integer"},
                "action": {"type": "string", "enum": ["mark_played", "dismiss", "restore"]},
            },
            "required": ["episode_id", "action"],
            "additionalProperties": False,
        },
    },
]


TOOLS.append(
    {
        "type": "function",
        "name": "search_library",
        "description": (
            "Search subscriptions and saved articles by topic, unheard status, kind and duration. "
            "Set saved_only for articles the user saved. "
            "Unknown durations cannot satisfy a maximum."
        ),
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "unheard": {"type": "boolean"},
                "saved_only": {"type": "boolean"},
                "kind": {"type": ["string", "null"], "enum": ["article", "audio", None]},
                "max_seconds": {"type": ["integer", "null"]},
            },
            "required": ["query", "unheard", "kind", "max_seconds", "saved_only"],
            "additionalProperties": False,
        },
    }
)

TOOLS.append(
    {
        "type": "function",
        "name": "undo_last_action",
        "description": "Undo the last voice filing or RSS subscription change. Does not undo email submissions.",
        "strict": True,
        "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
    }
)


def _function(name, description, properties):
    return {
        "type": "function",
        "name": name,
        "description": description,
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": list(properties),
            "additionalProperties": False,
        },
    }


TOOLS.extend(
    [
        _function(
            "ask_clarification",
            "Save an unresolved action and ask one answerable question. No action runs yet.",
            {
                "action": {"type": "string", "enum": clarifications.ACTIONS},
                "target_ids": {"type": "array", "items": {"type": "integer"}},
                "question": {"type": "string"},
                "remaining_request": {
                    "type": "string",
                    "description": "Later steps, or empty. For other, the entire unfinished request.",
                },
            },
        ),
        _function(
            "finish_response",
            "Report a limitation or an informational answer without taking an action.",
            {
                "status": {"type": "string", "enum": ["completed", "not_found", "unsupported", "failed"]},
                "message": {"type": "string"},
            },
        ),
    ]
)

INSTRUCTIONS += """
Use ask_clarification for every question; never signal a question by punctuation alone.
For a choice of supplied episodes, subscriptions or waiting senders, provide 2-3 target_ids
in spoken order and the intended action. Retain only unfinished later steps in remaining_request.
For an open question (including public discovery), use action other, no target_ids, and
retain the complete unfinished request. Ask about ONE missing detail. Do not ask for confirmation
when the user has already chosen. Accept neither, corrections, cancellation and new requests.
Examples: 'unsubscribe from The Rest Is' with History and Politics subscriptions requires a choice;
'follow the newsletter' with two waiting senders requires a choice, not a guess.
But 'subscribe to The Rest Is Entertainment' names a DIFFERENT specific show: search the
public directory. Never restrict new subscriptions to the user's existing subscriptions.
For a topic request within a known show, several episodes on that same topic can all satisfy
the request: choose the newest matching episode unless a specific part/version matters.
Do not ask a second question after the user already supplied the show and topic.
An arbitrary
acceptable match for 'play something short' does not require a question.
'Skip ahead thirty seconds' means seek, never dismiss, mark played, or restart an episode.
This server cannot seek: use finish_response unsupported if the device has not handled it.
'Get rid of this episode' means dismiss the episode; 'stop following this show' means unsubscribe.
A missing search result needs broader retrieval or not_found, not a fabricated choice.
Use finish_response for unsupported, not_found and failed outcomes. Never substitute a different action.
"""


TOOLS.append(
    _function(
        "play_matching_episode",
        "Filter the library and play a matching episode. Code calculates dates and selects latest/oldest. "
        "Use for date, latest, unheard, duration and kind requirements instead of choosing an episode ID.",
        {
            "feed_id": {"type": ["integer", "null"]},
            "query": {"type": "string", "description": "Topic/title terms only, without the show name or date words."},
            "day": {
                "type": ["string", "null"],
                "description": "Null unless a calendar day was requested. Latest alone means null.",
            },
            "order": {"type": "string", "enum": ["latest", "oldest", "any"]},
            "unheard": {"type": "boolean"},
            "saved_only": {"type": "boolean"},
            "kind": {"type": ["string", "null"], "enum": ["article", "audio", None]},
            "max_seconds": {"type": ["integer", "null"]},
        },
    )
)
INSTRUCTIONS += """
For latest/oldest, date, unheard, duration or kind constraints, use play_matching_episode.
LATEST DOES NOT MEAN TODAY. Use day null for 'latest In Our Time' or 'latest Astral Codex Ten'.
Only set day when the user explicitly requested a calendar day. Never add a date requirement.
Copy weekdays literally; code computes the most recent occurrence in the user's timezone,
including today. For a different week, ask for a specific date if necessary. Never compare
calendar dates or durations yourself. A feed_id identifies the supplied subscription;
query contains only topic/title terms. Empty matches mean not_found: do not relax constraints.
For an episode description without these constraints, search_library can expand retrieval.
"""


# Single actions return immediately. Compound requests explicitly continue
# after an action, preserving the fast path without throwing away later work.
_ACTION_TOOLS = {
    "undo_last_action",
    "subscribe_to_feed",
    "unsubscribe_from_feed",
    "approve_newsletter",
    "block_newsletter",
    "sign_up_for_newsletter",
    "read_newsletter_address",
    "play_episode",
    "play_matching_episode",
    "set_playback_speed",
    "file_episode",
}
for _tool in TOOLS:
    if _tool.get("name") in _ACTION_TOOLS:
        _tool["parameters"]["properties"]["continue_request"] = {
            "type": "boolean",
            "description": (
                "True if any part of this request still needs another tool after this action; "
                "false only for the last action."
            ),
        }
        _tool["parameters"]["required"].append("continue_request")

INSTRUCTIONS += """
For a compound request, carry out EVERY part in order. Set continue_request
true on each action except the last. For example, 'subscribe and play it'
needs subscribe, load episodes, then play. 'Play it at 1.5 times' needs play
then set speed. Do not ask the user to repeat the unfinished part.
Use the supplied duration, kind and listening state for requests like an
unheard article under twenty minutes. Unknown duration is not a known match.
'On screen' is distinct from 'now playing': 'read this' refers to the viewed
item when supplied. Recent completed actions provide context for corrections;
never claim to undo an action unless an available tool actually reverses it.
"""


def _combined(actions: list[InterpretResult], text: str = "", expects_reply: bool = False) -> InterpretResult:
    last = actions[-1]
    return InterpretResult(
        action=last.action,
        spoken_response=" ".join(item.spoken_response for item in actions) + (" " + text if text else ""),
        episode=last.episode,
        speed=last.speed,
        expects_reply=expects_reply,
        actions=list(actions) if len(actions) > 1 else [],
        status=last.status,
        clarification=last.clarification,
    )


@dataclass(frozen=True)
class AssistantDelta:
    text: str


@dataclass(frozen=True)
class ConversationFinished:
    result: InterpretResult


ConversationEvent = AssistantDelta | ConversationFinished


@dataclass
class _ToolResult:
    output: dict[str, Any]
    terminal: InterpretResult | None = None


async def converse(
    session: AsyncSession, client: ResponsesStreamingClient, **kwargs
) -> AsyncIterator[ConversationEvent]:
    async def spoken_events():
        emitted = False
        async for event in _with_clarification(session, client, **kwargs):
            if isinstance(event, AssistantDelta):
                emitted = True
            elif isinstance(event, ConversationFinished) and not emitted:
                yield AssistantDelta(event.result.spoken_response)
            yield event

    async with asyncio.timeout(120):
        if isinstance(client, OpenAIResponsesClient):
            async with client.connection():
                async for event in spoken_events():
                    yield event
        else:
            async for event in spoken_events():
                yield event


async def _with_clarification(session, client, *, clarification_id=None, selected_option_id=None, **kwargs):
    if clarification_id is None:
        if selected_option_id is not None:
            yield ConversationFinished(clarifications.unavailable())
            return
        async for event in _converse(session, client, **kwargs):
            yield event
        return
    user, answer = kwargs["user"], kwargs["transcript"]
    saved = await clarifications.load(session, user, clarification_id)
    if saved is None:
        yield ConversationFinished(clarifications.unavailable())
        return
    public = Clarification.model_validate(saved["public"])
    selected = clarifications.choice_for(public, answer, selected_option_id)
    cancel = clarifications.words(answer) in {"cancel", "cancel that", "never mind", "nevermind", "stop"}
    new_request = False
    if selected_option_id is not None and selected is None:
        yield ConversationFinished(
            InterpretResult(
                Action.UNKNOWN,
                public.question,
                expects_reply=True,
                status=CommandStatus.NEEDS_CLARIFICATION,
                clarification=public,
            )
        )
        return
    if selected is None and not cancel and public.choices:
        # This small classification sees only the saved choices. It cannot change
        # the pending action's arguments or silently invent a fourth choice.
        resolution = "unclear"
        choices = [item.id for item in public.choices]
        await session.commit()
        async for event in client.stream(
            instructions=(
                "Resolve the answer to this pending question. Choose an offered ID only if clearly identified. "
                "Yes alone cannot answer an either/or question. Neither is unclear; ask for a distinguishing detail. "
                "Use new_request only for an explicit different command, cancel for cancellation, otherwise unclear. "
                "Call resolve_answer without text."
            ),
            input_items=[
                {"role": "user", "content": json.dumps({"question": public.model_dump(mode="json"), "answer": answer})}
            ],
            tools=[
                _function(
                    "resolve_answer",
                    "Resolve a pending choice",
                    {"choice": {"type": "string", "enum": choices + ["cancel", "new_request", "unclear"]}},
                )
            ],
        ):
            if isinstance(event, ResponseCompleted):
                for call in event.response.get("output", []):
                    if call.get("name") == "resolve_answer":
                        try:
                            resolution = json.loads(call.get("arguments", "{}"))["choice"]
                        except (ValueError, KeyError, TypeError):
                            pass
        selected = resolution if resolution in choices else None
        cancel, new_request = resolution == "cancel", resolution == "new_request"
        if selected is None and not cancel and not new_request:
            question = public.question
            if clarifications.words(answer) in {"neither", "neither one", "something else"}:
                question = "What name or topic would distinguish the one you mean?"
                # Retain the intended request for a free-form correction.
                await check_cancelled(session)
                if not await clarifications.claim(session, user, clarification_id):
                    yield ConversationFinished(clarifications.unavailable())
                    return
                result = await clarifications.create(
                    session,
                    user,
                    action="other",
                    target_ids=[],
                    question=question,
                    remaining_request=saved["request"],
                    candidates=[],
                    request=saved["request"],
                )
            else:
                result = InterpretResult(
                    Action.UNKNOWN,
                    question,
                    expects_reply=True,
                    status=CommandStatus.NEEDS_CLARIFICATION,
                    clarification=public,
                )
            yield ConversationFinished(result)
            return
    await check_cancelled(session)
    if not await clarifications.claim(session, user, clarification_id):
        yield ConversationFinished(clarifications.unavailable())
        return
    if cancel:
        yield ConversationFinished(InterpretResult(Action.UNKNOWN, "Cancelled."))
        return
    if new_request or not public.choices:
        if new_request:
            kwargs["turns"] = ()
        else:
            kwargs["turns"] = [
                *kwargs.get("turns", ())[-4:],
                Turn(speaker=Speaker.HER, text=saved["remaining_request"] or saved["request"]),
                Turn(speaker=Speaker.APP, text=public.question),
            ]
        async for event in _converse(session, client, **kwargs):
            yield event
        return
    call = saved["calls"][selected]
    candidates = []
    if episode_id := call["arguments"].get("episode_id"):
        candidate = await service._now_playing(session, episode_id, user)
        if candidate is not None:
            candidates.append(candidate)
    outcome = await _call_tool(
        session,
        name=call["name"],
        arguments=json.dumps(call["arguments"]),
        user=user,
        allowed_episode_ids={item.id for item in candidates},
        candidates=candidates,
        country=kwargs.get("country"),
    )
    if outcome.terminal is None or not outcome.output.get("ok"):
        yield ConversationFinished(
            InterpretResult(
                Action.UNKNOWN, "That choice is no longer available. Please ask again.", status=CommandStatus.NOT_FOUND
            )
        )
        return
    if not saved["remaining_request"]:
        yield ConversationFinished(outcome.terminal)
        return
    kwargs["transcript"] = saved["remaining_request"]
    kwargs["turns"] = [Turn(speaker=Speaker.APP, text=outcome.terminal.spoken_response)]
    if outcome.terminal.episode:
        kwargs["now_playing_episode_id"] = outcome.terminal.episode.id
    async for event in _converse(session, client, **kwargs):
        if isinstance(event, ConversationFinished):
            following = event.result.actions or [event.result]
            yield ConversationFinished(
                _combined([outcome.terminal, *following], expects_reply=event.result.expects_reply)
            )
        else:
            yield event


async def _converse(
    session: AsyncSession,
    client: ResponsesStreamingClient,
    *,
    transcript: str,
    user: User,
    now_playing_episode_id: int | None = None,
    turns: Sequence[Turn] = (),
    country: str | None = None,
    supports_compound_actions: bool = True,
    viewed_episode_id: int | None = None,
    recent_actions: Sequence[str] = (),
    timezone: str = "UTC",
) -> AsyncIterator[ConversationEvent]:
    candidates = await service.build_candidates(session, user, service.spoken_so_far(transcript, turns))
    now_playing = await service._now_playing(session, now_playing_episode_id, user)
    if now_playing is not None and all(candidate.id != now_playing.id for candidate in candidates):
        candidates.append(now_playing)
    viewed = await service._now_playing(session, viewed_episode_id, user)
    if viewed is not None and all(item.id != viewed.id for item in candidates):
        candidates.append(viewed)
    allowed = {candidate.id for candidate in candidates}
    subscriptions = list(
        await session.scalars(
            select(Feed)
            .join(Subscription, Subscription.feed_id == Feed.id)
            .where(Subscription.user_id == user.id, Subscription.group_feed_id.is_(None))
            .order_by(Feed.title)
        )
    )

    pending = await newsletters.pending_senders(session, user)

    simple = clarifications.words(transcript)
    if re.fullmatch(
        r"(?:please )?(?:skip|jump|go|seek) (?:ahead|forward|back|backward)(?: .*)?", simple
    ) and not re.search(r"\b(speed|normal)\b", simple):
        yield ConversationFinished(
            InterpretResult(
                Action.UNKNOWN,
                "I cannot skip within an episode from here. Use the player's skip controls.",
                status=CommandStatus.UNSUPPORTED,
            )
        )
        return
    match = re.fullmatch(
        r"(?:please )?(?:unsubscribe|stop following)(?: me)?(?: from)? (.+)", transcript.strip(), re.I
    )
    remaining = ""
    if match:
        fragment = match[1].rstrip(".!?")
        matches = [feed for feed in subscriptions if service.matches_name(fragment, feed.title)]
        if not matches:
            parts = re.split(r"\s+(?:and then|and|then)\s+", fragment, maxsplit=1, flags=re.I)
            if len(parts) == 2:
                matches = [feed for feed in subscriptions if service.matches_name(parts[0].rstrip(","), feed.title)]
                remaining = parts[1]
        if remaining and not supports_compound_actions:
            yield ConversationFinished(
                InterpretResult(
                    Action.UNKNOWN,
                    "Please update Magpie to carry out several actions together.",
                    status=CommandStatus.UNSUPPORTED,
                )
            )
            return
        if 1 < len(matches) <= 3:
            result = await clarifications.create(
                session,
                user,
                action="unsubscribe",
                target_ids=[f.id for f in matches],
                question="Which show?",
                remaining_request=remaining,
                candidates=candidates,
                request=transcript,
            )
            yield ConversationFinished(result)
            return
    if len(pending) > 1 and simple in {
        "follow the newsletter",
        "subscribe to the newsletter",
        "follow it",
        "follow that newsletter",
    }:
        if len(pending) <= 3:
            result = await clarifications.create(
                session,
                user,
                action="approve_newsletter",
                target_ids=[p.feed.id for p in pending],
                question="Which newsletter?",
                remaining_request="",
                candidates=candidates,
                request=transcript,
            )
            yield ConversationFinished(result)
            return

    input_items = _conversation_input(
        transcript=transcript,
        turns=turns,
        candidates=candidates,
        subscriptions=subscriptions,
        now_playing=now_playing,
        pending=pending,
        today=utcnow().astimezone(ZoneInfo(timezone)).date(),
    )
    states = await service.positions.positions_for(session, user, allowed)
    details = ["Listening details (unknown duration must not be guessed):"]
    for item in candidates:
        state = states.get(item.id)
        details.append(
            f"[{item.id}] kind={'article' if item.is_article else 'audio'}; "
            f"duration_seconds={item.duration_seconds}; completed={bool(state and state.completed)}; "
            f"dismissed={bool(state and state.dismissed)}; position_seconds={state.position_seconds if state else 0}"
        )
    if viewed:
        details.append(f"On screen: [{viewed.id}] {viewed.title}")
    details.extend(f"Previously completed action: {item[:500]}" for item in recent_actions[-8:])
    input_items[-1]["content"] += "\n" + "\n".join(details)
    await session.commit()  # Release the read transaction before waiting on the model.
    completed_actions: list[InterpretResult] = []
    assistant_text = ""
    tools: list[dict[str, Any]] = TOOLS
    instructions = INSTRUCTIONS
    if not supports_compound_actions:
        tools = copy.deepcopy(TOOLS)
        for tool in tools:
            if tool.get("name") in _ACTION_TOOLS:
                tool["parameters"]["properties"]["continue_request"]["enum"] = [False]
        instructions += (
            " This older app supports one action per request. For compound requests, "
            "ask the user to update Magpie or ask for each step separately; "
            "do not perform only part of a compound request."
        )

    try:
        for _ in range(12):
            await check_cancelled(session)
            completed: dict[str, Any] | None = None
            round_text = ""
            async for event in client.stream(instructions=instructions, input_items=input_items, tools=tools):
                if isinstance(event, ResponseTextDelta):
                    round_text += event.text
                    assistant_text += event.text
                    yield AssistantDelta(event.text)
                elif isinstance(event, ResponseCompleted):
                    completed = event.response
            if completed is None:
                raise LLMError("OpenAI ended the response without completing it")

            output = completed.get("output") or []
            calls = [item for item in output if item.get("type") == "function_call"]
            if not calls:
                text = round_text.strip() or assistant_text.strip()
                if not text:
                    raise LLMError("OpenAI returned neither text nor an app action")
                result = (
                    _combined(completed_actions, text)
                    if completed_actions
                    else InterpretResult(
                        action=Action.UNKNOWN,
                        spoken_response=text,
                        expects_reply=False,
                    )
                )
                yield ConversationFinished(result)
                return

            input_items.extend(output)
            # A lookup between actions must not reuse the previous round's
            # terminal result and prematurely finish a compound request.
            terminal: InterpretResult | None = None
            continue_request = False
            if not supports_compound_actions and sum(call.get("name") in _ACTION_TOOLS for call in calls) > 1:
                yield ConversationFinished(
                    InterpretResult(Action.UNKNOWN, "Please update Magpie to carry out several actions together.")
                )
                return
            for call in calls:
                name = call.get("name", "")
                arguments = call.get("arguments", "{}")
                with logfire.span("conversation tool", tool_name=name) as span:
                    _annotate_tool_arguments(span, arguments)
                    async with asyncio.timeout(30):
                        tool_result = await _call_tool(
                            session,
                            name=name,
                            arguments=arguments,
                            user=user,
                            allowed_episode_ids=allowed,
                            candidates=candidates,
                            country=country,
                            transcript=transcript,
                            timezone=timezone,
                            request_context=" ".join(turn.text for turn in turns if turn.speaker is Speaker.HER),
                        )
                    _annotate_tool_result(span, tool_result)
                input_items.append(
                    {
                        "type": "function_call_output",
                        "call_id": call.get("call_id"),
                        "output": json.dumps(tool_result.output),
                    }
                )
                if tool_result.terminal is not None:
                    terminal = tool_result.terminal
                    completed_actions.append(terminal)
                    if terminal.expects_reply or terminal.status is not CommandStatus.COMPLETED:
                        yield ConversationFinished(_combined(completed_actions, expects_reply=terminal.expects_reply))
                        return
                    continue_request = supports_compound_actions and bool(
                        json.loads(arguments).get("continue_request", False)
                    )

            if terminal is not None and not continue_request:
                terminal = _combined(completed_actions)
                # The backend knows the actual title and outcome now. A second
                # model round trip merely paraphrases that fact and was adding
                # several seconds to every successful command.
                yield AssistantDelta(terminal.spoken_response)
                yield ConversationFinished(terminal)
                return

        if completed_actions:
            yield ConversationFinished(
                _combined(completed_actions, "The remaining steps did not finish. Please ask for those again.")
            )
            return
        raise LLMError("OpenAI exceeded the app tool-call limit")
    except (LLMError, TimeoutError):
        if not completed_actions:
            raise
        yield ConversationFinished(
            _combined(completed_actions, "The remaining steps did not finish. Please ask for those again.")
        )


def _annotate_tool_arguments(span: Any, arguments: str) -> None:
    """Make a tool choice legible without bypassing transcript privacy."""
    if not settings.telemetry_transcripts:
        return
    try:
        values = json.loads(arguments)
    except json.JSONDecodeError:
        span.set_attribute("arguments_valid", False)
        return
    if not isinstance(values, dict):
        span.set_attribute("arguments_valid", False)
        return
    span.set_attribute("arguments_valid", True)
    for key in (
        "query",
        "url",
        "feed_url",
        "feed_id",
        "episode_id",
        "episode_query",
        "action",
        "speed",
        "newsletter_id",
    ):
        value = values.get(key)
        if value is not None:
            span.set_attribute(f"tool_{key}", value)


def _annotate_tool_result(span: Any, result: _ToolResult) -> None:
    """Attach the small outcome fields needed to understand a tool chain."""
    for key in ("ok", "status", "title", "feed_url", "show", "speed", "error"):
        value = result.output.get(key)
        if value is not None:
            span.set_attribute(f"tool_result_{key}", value)
    if result.terminal is not None:
        span.set_attribute("terminal_action", result.terminal.action.value)


def _conversation_input(
    *,
    transcript: str,
    turns: Sequence[Turn],
    candidates: list[Candidate],
    subscriptions: list[Feed],
    now_playing: Candidate | None,
    pending: Sequence[PendingSender] = (),
    today: date | None = None,
) -> list[dict[str, Any]]:
    items = [
        {
            "role": "user" if turn.speaker is Speaker.HER else "assistant",
            "content": turn.text,
        }
        for turn in turns
    ]
    lines = [f"Today is {(today or date.today()).isoformat()}.", f'User said: "{transcript}"', ""]
    if now_playing is not None:
        lines.append(f"Now playing: [{now_playing.id}] {now_playing.title} — {now_playing.feed_title}")
    lines.append("Subscriptions (valid IDs for unsubscribe):")
    lines.extend(f"[{feed.id}] {feed.title} — {feed.url}" for feed in subscriptions)
    lines.append("")
    if pending:
        lines.append("Newsletter senders waiting for an answer (valid IDs for approve_newsletter/block_newsletter):")
        for item in pending:
            line = f"[{item.feed.id}] {item.feed.title} — {item.feed.description} — {item.message_count} message(s)"
            if item.latest_title:
                line += f" — latest: {item.latest_title}"
            lines.append(line)
        lines.append("")
    lines.append("Available episodes/articles (valid IDs for playback or filing):")
    for candidate in candidates:
        published = candidate.published_at.date().isoformat() if candidate.published_at else "undated"
        lines.append(f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}")
        if candidate.description:
            lines.append(f"    {candidate.description}")
    items.append({"role": "user", "content": "\n".join(lines)})
    return items


async def _call_tool(session, **kwargs) -> _ToolResult:
    await check_cancelled(session)
    try:
        args = json.loads(kwargs["arguments"])
        before = await undo.snapshot(session, kwargs["user"], kwargs["name"], args)
    except (ValueError, TypeError, AttributeError):
        before = None
    result = await _execute_tool(session, **kwargs)
    if (
        result.terminal is not None
        and result.output.get("ok")
        and kwargs["name"] in _ACTION_TOOLS
        and result.terminal.status is CommandStatus.COMPLETED
    ):
        await undo.remember(session, kwargs["user"], before)
    return result


async def _execute_tool(
    session: AsyncSession,
    *,
    name: str,
    arguments: str,
    user: User,
    allowed_episode_ids: set[int],
    candidates: list[Candidate],
    country: str | None,
    transcript: str = "",
    timezone: str = "UTC",
    request_context: str = "",
) -> _ToolResult:
    try:
        args = json.loads(arguments)
    except json.JSONDecodeError:
        return _ToolResult({"ok": False, "error": "Tool arguments were not valid JSON."})

    try:
        if name == "ask_clarification":
            day = selection.requested_day(transcript) if args.get("action") == "play_episode" else None
            date_window = None
            if day:
                start, end = selection.date_bounds(day, timezone, utcnow())
                valid = {
                    item.id
                    for item in candidates
                    if item.published_at is not None
                    and start
                    <= (
                        item.published_at.replace(tzinfo=UTC)
                        if item.published_at.tzinfo is None
                        else item.published_at
                    )
                    < end
                }
                if not set(args.get("target_ids", [])) <= valid:
                    return _ToolResult(
                        {
                            "ok": False,
                            "error": f"Those choices do not match {day}. Use play_matching_episode with day={day}, "
                            "feed_id=null if no show was named, order=latest. Do not ask the user to compare dates.",
                        }
                    )
                date_window = (start, end)
            result = await clarifications.create(
                session,
                user,
                action=args["action"],
                target_ids=args["target_ids"],
                question=args["question"],
                remaining_request=args["remaining_request"],
                candidates=candidates,
                request=transcript,
                date_window=date_window,
            )
            return _ToolResult({"ok": True}, result)
        if name == "finish_response":
            status = CommandStatus(args["status"])
            if status is CommandStatus.NEEDS_CLARIFICATION or not str(args["message"]).strip():
                raise ValueError("Use ask_clarification for questions")
            return _ToolResult({"ok": True}, InterpretResult(Action.UNKNOWN, str(args["message"]), status=status))
        if name == "play_matching_episode":
            maximum = args.get("max_seconds")
            if maximum is not None and (type(maximum) is not int or maximum <= 0):
                raise ValueError("Duration must be positive seconds")
            if args.get("kind") not in {None, "audio", "article"} or args.get("order") not in {
                "latest",
                "oldest",
                "any",
            }:
                raise ValueError("Invalid selection constraints")
            feed_id = args.get("feed_id")
            external = False
            if feed_id is not None and not await session.scalar(
                select(Subscription.id).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
            ):
                # Public discovery is allowed only after episodes from that feed
                # were actually offered. Never broaden to arbitrary catalog IDs.
                external = bool(
                    await session.scalar(
                        select(Episode.id)
                        .join(Feed)
                        .where(
                            Episode.id.in_(allowed_episode_ids),
                            Episode.feed_id == feed_id,
                            or_(Feed.owner_user_id.is_(None), Feed.owner_user_id == user.id),
                        )
                        .limit(1)
                    )
                )
                if not external:
                    raise ValueError("Feed must be a supplied subscription or loaded show")
            day = args.get("day")
            if (
                day == "today"
                and transcript
                and not re.search(
                    r"\b(today|this morning|this afternoon|this evening|tonight)\b",
                    (request_context + " " + transcript).casefold(),
                )
            ):
                return _ToolResult(
                    {"ok": False, "error": "Latest does not mean today. Set day to null unless a day was requested."}
                )
            start, end = selection.date_bounds(args.get("day"), timezone, utcnow())
            loaded = await library.search(
                session,
                user,
                query=str(args.get("query", "")),
                unheard=bool(args.get("unheard")),
                saved_only=bool(args.get("saved_only")),
                kind=args.get("kind"),
                max_seconds=maximum,
                feed_id=feed_id,
                published_after=start,
                published_before=end,
                oldest=args["order"] == "oldest",
                chronological=args["order"] != "any",
                external_feed=external,
            )
            if args["order"] != "any":
                loaded = selection.ordered(loaded, latest=args["order"] == "latest")
            if not loaded:
                return _ToolResult(
                    {"ok": True},
                    InterpretResult(
                        Action.UNKNOWN,
                        "I could not find an episode matching those requirements.",
                        status=CommandStatus.NOT_FOUND,
                    ),
                )
            chosen = loaded[0]
            allowed_episode_ids.add(chosen.id)
            if all(item.id != chosen.id for item in candidates):
                candidates.append(chosen)
            return await _execute_tool(
                session,
                name="play_episode",
                arguments=json.dumps({"episode_id": chosen.id}),
                user=user,
                allowed_episode_ids=allowed_episode_ids,
                candidates=candidates,
                country=country,
            )
        if name == "search_library":
            maximum = args.get("max_seconds")
            if maximum is not None and (type(maximum) is not int or maximum <= 0):
                return _ToolResult({"ok": False, "error": "Duration must be positive seconds."})
            loaded = await library.search(
                session,
                user,
                query=str(args.get("query", "")),
                unheard=bool(args.get("unheard")),
                saved_only=bool(args.get("saved_only")),
                kind=args.get("kind"),
                max_seconds=maximum,
            )
            allowed_episode_ids.update(item.id for item in loaded)
            known = {item.id for item in candidates}
            candidates.extend(item for item in loaded if item.id not in known)
            return _ToolResult({"ok": True, "episodes": await _candidate_details(session, user, loaded)})

        if name == "undo_last_action":
            result = await undo.undo_last(session, user)
            return _ToolResult({"ok": True}, result)

        if name == "search_podcast_directory":
            matches = await search_podcasts(str(args["query"]), limit=8, strict=False, country=country)
            return _ToolResult(
                {
                    "ok": True,
                    "results": [
                        {
                            "title": match.title,
                            "publisher": match.publisher,
                            "feed_url": match.feed_url,
                        }
                        for match in matches
                    ],
                }
            )

        if name == "inspect_publication":
            feed_url, parsed = await resolve_feed(str(args["url"]))
            return _ToolResult({"ok": True, "title": parsed.title, "feed_url": feed_url})

        if name == "subscribe_to_feed":
            try:
                feed = await feed_service.subscribe(session, str(args["feed_url"]), user)
                result = InterpretResult(Action.SUBSCRIBED, f"Subscribed to {feed.title}.")
                return _ToolResult({"ok": True, "title": feed.title, "status": "subscribed"}, result)
            except AlreadySubscribedError:
                feed = await feed_service.ensure_feed(session, str(args["feed_url"]))
                result = InterpretResult(Action.UNKNOWN, f"You are already subscribed to {feed.title}.")
                return _ToolResult({"ok": True, "title": feed.title, "status": "already_subscribed"}, result)

        if name == "unsubscribe_from_feed":
            feed_id = int(args["feed_id"])
            feed = next(
                iter(
                    await session.scalars(
                        select(Feed)
                        .join(Subscription, Subscription.feed_id == Feed.id)
                        .where(Subscription.user_id == user.id, Feed.id == feed_id)
                    )
                ),
                None,
            )
            if feed is None:
                return _ToolResult({"ok": False, "error": "That feed ID is not one of the user's subscriptions."})
            await feed_service.unsubscribe(session, feed.id, user)
            result = InterpretResult(Action.UNSUBSCRIBED, f"Unsubscribed from {feed.title}.")
            return _ToolResult({"ok": True, "title": feed.title, "status": "unsubscribed"}, result)

        if name == "approve_newsletter":
            result = await service.approve_newsletter(session, user, int(args["newsletter_id"]))
            ok = result.action is Action.SUBSCRIBED
            return _ToolResult(
                {
                    "ok": ok,
                    "status": "following" if ok else "not_waiting",
                    "error": None if ok else result.spoken_response,
                },
                result if ok else None,
            )

        if name == "block_newsletter":
            result = await service.block_newsletter(session, user, int(args["newsletter_id"]))
            ok = result.action is Action.UNSUBSCRIBED
            return _ToolResult(
                {
                    "ok": ok,
                    "status": "blocked" if ok else "not_waiting",
                    "error": None if ok else result.spoken_response,
                },
                result if ok else None,
            )

        if name == "read_newsletter_address":
            result = await service.newsletter_address(session, user)
            return _ToolResult({"ok": True, "status": "address_read"}, result)

        if name == "sign_up_for_newsletter":
            try:
                outcome = await newsletters.sign_up(session, user, str(args["url"]))
            except newsletters.NewslettersDisabledError:
                return _ToolResult({"ok": False, "error": "Newsletters by email are not set up on this server."})
            result = InterpretResult(Action.UNKNOWN, outcome.spoken_response)
            return _ToolResult(
                {
                    "ok": outcome.status == newsletters.SIGNUP_SUBMITTED,
                    "status": outcome.status,
                    "title": outcome.publication,
                    "reason": outcome.reason,
                },
                result,
            )

        if name == "load_show_episodes":
            feed = await feed_service.ensure_feed(session, str(args["feed_url"]))
            loaded = await service.feed_candidates(session, feed.id, str(args.get("episode_query") or ""), user=user)
            allowed_episode_ids.update(candidate.id for candidate in loaded)
            known_ids = {item.id for item in candidates}
            candidates.extend(candidate for candidate in loaded if candidate.id not in known_ids)
            return _ToolResult(
                {
                    "ok": True,
                    "show": feed.title,
                    "feed_id": feed.id,
                    "episodes": await _candidate_details(session, user, loaded),
                }
            )

        if name == "play_episode":
            if re.search(
                r"\b(latest|newest|oldest|unheard|today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"
                r"|\bunder .+ minutes?",
                transcript.casefold(),
            ):
                return _ToolResult(
                    {"ok": False, "error": "Use play_matching_episode to enforce the requested constraints."}
                )
            episode_id = int(args["episode_id"])
            if episode_id not in allowed_episode_ids:
                return _ToolResult({"ok": False, "error": "That episode ID was not supplied by Magpie."})
            episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
            if episode is None:
                return _ToolResult({"ok": False, "error": "That episode no longer exists."})
            if args.get("published_after"):
                published = episode.published_at
                if published is not None and published.tzinfo is None:
                    published = published.replace(tzinfo=UTC)
                if published is None or not (
                    datetime.fromisoformat(args["published_after"])
                    <= published
                    < datetime.fromisoformat(args["published_before"])
                ):
                    return _ToolResult({"ok": False, "error": "That episode no longer matches the requested date."})
            result = InterpretResult(Action.PLAY_EPISODE, f"Playing {service._spoken_title(episode.title)}.", episode)
            return _ToolResult({"ok": True, "title": episode.title, "status": "ready_to_play"}, result)

        if name == "set_playback_speed":
            result = service._set_speed(float(args["speed"]))
            return _ToolResult(
                {"ok": result.action is Action.SET_SPEED, "speed": result.speed, "status": "speed_set"},
                result,
            )

        if name == "file_episode":
            action = Action(str(args["action"]))
            result = await service._file_episode(session, action, int(args["episode_id"]), candidates, user)
            return _ToolResult(
                {
                    "ok": result.action is action,
                    "status": result.action.value,
                    "title": result.episode.title if result.episode else None,
                },
                result if result.action is action else None,
            )

        return _ToolResult({"ok": False, "error": f"Unknown tool: {name}"})
    except (KeyError, TypeError, ValueError) as exc:
        return _ToolResult({"ok": False, "error": f"Invalid arguments: {exc}"})
    except (FeedFetchError, FeedParseError, PodcastSearchError) as exc:
        logger.info("conversation tool %s failed: %s", name, exc)
        return _ToolResult({"ok": False, "error": "The publication could not be loaded."})


async def _candidate_details(session, user, candidates):
    states = await service.positions.positions_for(session, user, [item.id for item in candidates])
    return [
        {
            "id": item.id,
            "title": item.title,
            "description": item.description,
            "kind": "article" if item.is_article else "audio",
            "duration_seconds": item.duration_seconds,
            "completed": bool(states.get(item.id) and states[item.id].completed),
            "dismissed": bool(states.get(item.id) and states[item.id].dismissed),
            "published_at": item.published_at.isoformat() if item.published_at else None,
        }
        for item in candidates
    ]
