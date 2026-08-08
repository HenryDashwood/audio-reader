"""Turn a spoken request into an action, using an LLM to pick the episode."""

import logging

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.commands.intents import Action, Candidate, InterpretResult, ModelDecision
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, matches_name, search_podcasts
from audioreader.feeds.service import AlreadySubscribedError
from audioreader.models import Episode, Feed
from audioreader.text import summarise

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You help a blind listener control a podcast app by voice.

You will be given what she said and a numbered list of episodes she subscribes
to. Decide what she wants and reply with the matching action.

- Choose play_episode only when one episode is a clear match. She may refer to
  an episode by topic, by guest, by date ("Tuesday's one"), or by position
  ("the latest"). Prefer the most recent episode when a request is ambiguous
  between several of the same show.
- If she names a show, only episodes from that show may be chosen. A show name
  narrows the choice, it is not a hint: "the latest In Our Time" means the most
  recent In Our Time episode, never a newer episode of something else. If that
  show has no episodes in the list, choose unknown and say so.
- Choose subscribe when she wants to follow a show she does not have yet
  ("subscribe to", "add", "start following"). Put just the show's name in
  search_query — no "subscribe to", no "the podcast", nothing else. Leave
  spoken_response empty: the app says what was actually found.
- Choose unsubscribe when she wants to stop following a show she already has
  ("unsubscribe from", "remove", "stop following", "get rid of"). Put just the
  show's name in search_query, and leave spoken_response empty.
- Choose unknown when nothing matches, or when several episodes match equally
  well and guessing would be worse than asking.
- episode_id must be copied exactly from the list. Never invent one.
- spoken_response is read aloud to her and she waits through every word of it
  before the episode starts, so make it as short as possible.
  For play_episode use at most six words: enough to recognise the episode and
  catch a wrong pick, nothing more. "Playing Diana Pasulka." or "Playing the
  Delian League." — never the show name, episode number, guest list or topic
  unless that is the only way to identify it.
  For unknown, one short question naming what you need.
"""


async def build_candidates(session: AsyncSession, limit: int | None = None) -> list[Candidate]:
    """The episodes the model may choose between, newest first.

    Only episodes with audio: article text-to-speech is a later increment, so
    offering an article here would produce an action the app cannot perform.
    """
    limit = limit if limit is not None else settings.command_candidate_limit
    episodes = await session.scalars(
        select(Episode)
        .where(Episode.audio_url.is_not(None))
        .options(joinedload(Episode.feed))
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return [
        Candidate(
            id=episode.id,
            title=episode.title,
            feed_title=episode.feed.title,
            # The model sees stripped, truncated text: feed descriptions are
            # HTML soup and would otherwise dominate the token bill.
            description=summarise(episode.description, limit=300),
            published_at=episode.published_at,
            duration_seconds=episode.duration_seconds,
        )
        for episode in episodes
    ]


def build_prompt(transcript: str, candidates: list[Candidate]) -> str:
    lines = ["She said:", f'"{transcript}"', "", "Episodes she subscribes to:"]
    for candidate in candidates:
        published = (
            candidate.published_at.strftime("%A %d %B %Y") if candidate.published_at else "undated"
        )
        duration = (
            f"{round(candidate.duration_seconds / 60)} min" if candidate.duration_seconds else ""
        )
        header = f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}"
        lines.append(f"{header} — {duration}" if duration else header)
        if candidate.description:
            lines.append(f"    {candidate.description}")
    return "\n".join(lines)


async def interpret(session: AsyncSession, llm, transcript: str) -> InterpretResult:
    candidates = await build_candidates(session)

    raw = await llm.decide(
        system=SYSTEM_PROMPT,
        user=build_prompt(transcript, candidates),
        output_model=ModelDecision,
    )

    try:
        decision = ModelDecision.model_validate(raw)
    except ValidationError as exc:
        logger.warning("model returned an unusable decision (%s): %r", exc, raw)
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    if decision.action is Action.SUBSCRIBE:
        return await _subscribe(session, decision.search_query)

    if decision.action is Action.UNSUBSCRIBE:
        return await _unsubscribe(session, decision.search_query)

    if decision.action is not Action.PLAY_EPISODE:
        return InterpretResult(action=Action.UNKNOWN, spoken_response=decision.spoken_response)

    if not candidates:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You have no podcasts yet. Say subscribe, and the name of a show.",
        )

    # Never trust the model with a primary key: only ids we offered are valid.
    if decision.episode_id not in {candidate.id for candidate in candidates}:
        logger.warning("model chose episode_id %r, which was not offered", decision.episode_id)
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    episode = await session.get(Episode, decision.episode_id)
    if episode is None:
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


async def _subscribe(session: AsyncSession, query: str | None) -> InterpretResult:
    """Find a show by spoken name and follow it."""
    if not query or not query.strip():
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Which show would you like to subscribe to?",
        )

    try:
        matches = await search_podcasts(query)
    except PodcastSearchError as exc:
        logger.warning("podcast search failed for %r: %s", query, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="I could not search for podcasts just now. Please try again shortly.",
        )

    if not matches:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I could not find a podcast called {query}.",
        )

    best = matches[0]
    try:
        await feed_service.subscribe(session, best.feed_url)
    except AlreadySubscribedError:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"You are already subscribed to {best.title}.",
        )
    except (FeedFetchError, FeedParseError) as exc:
        logger.warning("could not subscribe to %s: %s", best.feed_url, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I found {best.title}, but could not load its episodes.",
        )

    return InterpretResult(
        action=Action.SUBSCRIBED,
        spoken_response=f"Subscribed to {best.title}.",
    )


async def _unsubscribe(session: AsyncSession, query: str | None) -> InterpretResult:
    """Stop following a show she already has."""
    if not query or not query.strip():
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Which show would you like to remove?",
        )

    feeds = (await session.scalars(select(Feed))).all()
    if not feeds:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You are not subscribed to anything yet.",
        )

    matches = [feed for feed in feeds if matches_name(query, feed.title)]

    if not matches:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"You are not subscribed to {query}.",
        )

    if len(matches) > 1:
        # Removing the wrong show silently is far worse than one more question.
        names = " or ".join(feed.title for feed in matches)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"Did you mean {names}?",
        )

    feed = matches[0]
    title = feed.title
    await session.delete(feed)  # episodes cascade
    await session.commit()
    return InterpretResult(
        action=Action.UNSUBSCRIBED,
        spoken_response=f"Unsubscribed from {title}.",
    )


_CLARIFY = "Sorry, I did not catch which episode you meant. Could you say that again?"
