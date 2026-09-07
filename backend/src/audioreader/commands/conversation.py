"""A streamed, model-led voice conversation with explicit app tools.

The model owns interpretation and clarification. Python owns only the hard
boundary: it validates identifiers and URLs, performs the chosen action, and
reports what actually happened. In particular, a publication name is not
passed through a second name-matching classifier after the model has resolved
it to a feed.
"""

import asyncio
import copy
import json
import logging
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass
from datetime import date
from typing import Any

import logfire
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.commands import library, service, undo
from audioreader.commands.intents import Action, Candidate, InterpretResult, Speaker, Turn
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
from audioreader.models import Episode, Feed, Subscription, User
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
    async with asyncio.timeout(120):
        if isinstance(client, OpenAIResponsesClient):
            async with client.connection():
                async for event in _converse(session, client, **kwargs):
                    yield event
        else:
            async for event in _converse(session, client, **kwargs):
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

    input_items = _conversation_input(
        transcript=transcript,
        turns=turns,
        candidates=candidates,
        subscriptions=subscriptions,
        now_playing=now_playing,
        pending=pending,
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
                    _combined(completed_actions, text, text.rstrip().endswith("?"))
                    if completed_actions
                    else InterpretResult(
                        action=Action.UNKNOWN,
                        spoken_response=text,
                        expects_reply=text.rstrip().endswith("?"),
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
) -> list[dict[str, Any]]:
    items = [
        {
            "role": "user" if turn.speaker is Speaker.HER else "assistant",
            "content": turn.text,
        }
        for turn in turns
    ]
    lines = [f"Today is {date.today().isoformat()}.", f'User said: "{transcript}"', ""]
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
    if result.terminal is not None and result.output.get("ok"):
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
) -> _ToolResult:
    try:
        args = json.loads(arguments)
    except json.JSONDecodeError:
        return _ToolResult({"ok": False, "error": "Tool arguments were not valid JSON."})

    try:
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
                    "episodes": await _candidate_details(session, user, loaded),
                }
            )

        if name == "play_episode":
            episode_id = int(args["episode_id"])
            if episode_id not in allowed_episode_ids:
                return _ToolResult({"ok": False, "error": "That episode ID was not supplied by Magpie."})
            episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
            if episode is None:
                return _ToolResult({"ok": False, "error": "That episode no longer exists."})
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
