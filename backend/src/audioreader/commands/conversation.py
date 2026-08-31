"""A streamed, model-led voice conversation with explicit app tools.

The model owns interpretation and clarification. Python owns only the hard
boundary: it validates identifiers and URLs, performs the chosen action, and
reports what actually happened. In particular, a publication name is not
passed through a second name-matching classifier after the model has resolved
it to a feed.
"""

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

from audioreader.commands import service
from audioreader.commands.intents import Action, Candidate, InterpretResult, Speaker, Turn
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.discovery import resolve_feed
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, search_podcasts
from audioreader.feeds.service import AlreadySubscribedError
from audioreader.llm.client import LLMError
from audioreader.llm.openai_responses import (
    ResponseCompleted,
    ResponsesStreamingClient,
    ResponseTextDelta,
)
from audioreader.models import Episode, Feed, Subscription, User

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
    session: AsyncSession,
    client: ResponsesStreamingClient,
    *,
    transcript: str,
    user: User,
    now_playing_episode_id: int | None = None,
    turns: Sequence[Turn] = (),
    country: str | None = None,
) -> AsyncIterator[ConversationEvent]:
    candidates = await service.build_candidates(session, user, service.spoken_so_far(transcript, turns))
    now_playing = await service._now_playing(session, now_playing_episode_id)
    if now_playing is not None and all(candidate.id != now_playing.id for candidate in candidates):
        candidates.append(now_playing)
    allowed = {candidate.id for candidate in candidates}
    subscriptions = list(
        await session.scalars(
            select(Feed)
            .join(Subscription, Subscription.feed_id == Feed.id)
            .where(Subscription.user_id == user.id)
            .order_by(Feed.title)
        )
    )

    input_items = _conversation_input(
        transcript=transcript,
        turns=turns,
        candidates=candidates,
        subscriptions=subscriptions,
        now_playing=now_playing,
    )
    terminal: InterpretResult | None = None
    assistant_text = ""
    tools: list[dict[str, Any]] = TOOLS

    for _ in range(6):
        completed: dict[str, Any] | None = None
        round_text = ""
        async for event in client.stream(instructions=INSTRUCTIONS, input_items=input_items, tools=tools):
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
            result = terminal or InterpretResult(
                action=Action.UNKNOWN,
                spoken_response=text,
                expects_reply=text.rstrip().endswith("?"),
            )
            if terminal is not None:
                result.spoken_response = text
            yield ConversationFinished(result)
            return

        input_items.extend(output)
        for call in calls:
            name = call.get("name", "")
            arguments = call.get("arguments", "{}")
            with logfire.span("conversation tool", tool_name=name) as span:
                _annotate_tool_arguments(span, arguments)
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

        if terminal is not None:
            # The backend knows the actual title and outcome now. A second
            # model round trip merely paraphrases that fact and was adding
            # several seconds to every successful command.
            yield AssistantDelta(terminal.spoken_response)
            yield ConversationFinished(terminal)
            return

    raise LLMError("OpenAI exceeded the app tool-call limit")


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
    for key in ("query", "url", "feed_url", "feed_id", "episode_id", "episode_query", "action", "speed"):
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
    lines.append("Available episodes/articles (valid IDs for playback or filing):")
    for candidate in candidates:
        published = candidate.published_at.date().isoformat() if candidate.published_at else "undated"
        lines.append(f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}")
        if candidate.description:
            lines.append(f"    {candidate.description}")
    items.append({"role": "user", "content": "\n".join(lines)})
    return items


async def _call_tool(
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

        if name == "load_show_episodes":
            feed = await feed_service.ensure_feed(session, str(args["feed_url"]))
            loaded = await service.feed_candidates(session, feed.id, str(args.get("episode_query") or ""))
            allowed_episode_ids.update(candidate.id for candidate in loaded)
            known_ids = {item.id for item in candidates}
            candidates.extend(candidate for candidate in loaded if candidate.id not in known_ids)
            return _ToolResult(
                {
                    "ok": True,
                    "show": feed.title,
                    "episodes": [
                        {
                            "id": item.id,
                            "title": item.title,
                            "published_at": item.published_at.isoformat() if item.published_at else None,
                        }
                        for item in loaded
                    ],
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
