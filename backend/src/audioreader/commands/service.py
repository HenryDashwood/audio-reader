"""Turn a spoken request into an action, using an LLM to pick the episode."""

import logging
import re

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.commands.intents import Action, Candidate, InterpretResult, ModelDecision
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.discovery import (
    DiscoveredFeed,
    find_feed_by_name,
    resolve_feed,
    spoken_domains,
)
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, matches_name, search_podcasts
from audioreader.feeds.service import AlreadySubscribedError
from audioreader.models import PLAYABLE_EPISODE, Episode, Feed, Subscription, User
from audioreader.text import summarise

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You help a blind listener control a listening app by voice.
The app plays podcast episodes and reads written articles aloud; articles are
marked in the list and are chosen exactly like episodes.

You will be given what she said and a numbered list of episodes and articles
she subscribes to. Decide what she wants and reply with the matching action.

- Choose play_episode only when one item is a clear match. She may refer to
  it by topic, by guest, by date ("Tuesday's one"), or by position
  ("the latest"). Prefer the most recent item when a request is ambiguous
  between several of the same show.
- If she names a show, only episodes from that show may be chosen. A show name
  narrows the choice, it is not a hint: "the latest In Our Time" means the most
  recent In Our Time episode, never a newer episode of something else.
- Choose play_from_show when she asks to hear an episode of a show that has no
  episodes in the list — she can listen without subscribing. Put just the
  show's name in search_query. Put what identifies the episode in
  episode_query ("the one about Agincourt"), or leave it empty when she wants
  the latest. Leave spoken_response empty: the app says what was found.
- Choose subscribe when she wants to follow a show she does not have yet
  ("subscribe to", "add", "start following"). Shows include blogs, newsletters
  and Substacks as well as podcasts — "subscribe to Astral Codex Ten" is a
  subscribe even though it is a blog. Put just the show's name in
  search_query — no "subscribe to", no "the podcast", nothing else. If she
  names a website ("the RSS feed of astralcodexten.com"), keep the domain in
  search_query exactly as she said it — naming a site means she wants that
  site's own feed. Leave spoken_response empty: the app says what was
  actually found.
- Choose unsubscribe when she wants to stop following a show she already has
  ("unsubscribe from", "remove", "stop following", "get rid of"). Put just the
  show's name in search_query, and leave spoken_response empty.
- Choose set_speed when she asks for a playback speed ("one and a half times",
  "play at double speed", "half speed", "normal speed"). Put the multiplier in
  speed: "double" is 2, "normal" is 1, "half" is 0.5. Sensible values are 0.5
  to 3. Leave spoken_response empty: the app confirms the speed itself.
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


#: The second, scoped stage of play_from_show: one show's episodes only, so
#: the only decision left is which episode she described.
EPISODE_PICK_PROMPT = """You help a blind listener control a listening app by
voice. The app plays podcast episodes and reads written articles aloud.

She asked for an episode of one particular show. You will be given what she
said and a numbered list of that show's episodes and articles. Choose
play_episode with the item that matches what she described — by topic, by
guest, or by date — or unknown when nothing clearly matches.

- episode_id must be copied exactly from the list. Never invent one.
- spoken_response is read aloud and she waits through every word of it before
  the episode starts. For play_episode use at most six words, enough to catch
  a wrong pick: "Playing the Agincourt episode."
  For unknown, one short question naming what you need.
"""


async def build_candidates(
    session: AsyncSession, user: User, limit: int | None = None
) -> list[Candidate]:
    """The episodes and articles the model may choose between, newest first.

    Only the user's own subscriptions, and only playable items: audio, or
    article text the app can read aloud.
    """
    limit = limit if limit is not None else settings.command_candidate_limit
    episodes = await session.scalars(
        select(Episode)
        .join(Subscription, Subscription.feed_id == Episode.feed_id)
        .where(Subscription.user_id == user.id, PLAYABLE_EPISODE)
        .options(joinedload(Episode.feed))
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return _to_candidates(episodes)


async def feed_candidates(
    session: AsyncSession, feed_id: int, limit: int | None = None
) -> list[Candidate]:
    """One show's playable items, newest first, subscription not required."""
    limit = limit if limit is not None else settings.command_candidate_limit
    episodes = await session.scalars(
        select(Episode)
        .where(Episode.feed_id == feed_id, PLAYABLE_EPISODE)
        .options(joinedload(Episode.feed))
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return _to_candidates(episodes)


def _to_candidates(episodes) -> list[Candidate]:
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
            is_article=episode.audio_url is None,
        )
        for episode in episodes
    ]


def build_prompt(transcript: str, candidates: list[Candidate]) -> str:
    lines = ["She said:", f'"{transcript}"', "", "Episodes and articles she subscribes to:"]
    for candidate in candidates:
        published = (
            candidate.published_at.strftime("%A %d %B %Y") if candidate.published_at else "undated"
        )
        header = f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}"
        if candidate.is_article:
            header += " — article"
        elif candidate.duration_seconds:
            header += f" — {round(candidate.duration_seconds / 60)} min"
        lines.append(header)
        if candidate.description:
            lines.append(f"    {candidate.description}")
    return "\n".join(lines)


async def interpret(
    session: AsyncSession, llm, transcript: str, user: User, discovery_llm=None
) -> InterpretResult:
    # Feed discovery gets its own client (web search, long timeout); without
    # one, the ordinary client still handles the easy, well-known cases.
    discovery_llm = discovery_llm if discovery_llm is not None else llm
    candidates = await build_candidates(session, user)

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
        return await _subscribe(session, decision.search_query, transcript, user, discovery_llm)

    if decision.action is Action.PLAY_FROM_SHOW:
        return await _play_from_show(
            session, llm, transcript, decision.search_query, decision.episode_query, discovery_llm
        )

    if decision.action is Action.UNSUBSCRIBE:
        return await _unsubscribe(session, decision.search_query, user)

    if decision.action is Action.SET_SPEED:
        return _set_speed(decision.speed)

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

    # Feed loaded eagerly: the router folds show artwork into the response.
    episode = await session.get(Episode, decision.episode_id, options=[joinedload(Episode.feed)])
    if episode is None:
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


def _set_speed(speed: float | None) -> InterpretResult:
    """Hand a validated multiplier to the app; the phone applies it."""
    if speed is None or not (0.5 <= speed <= 3.0):
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="What speed would you like? Between half and triple speed works.",
        )
    # Round to the nearest quarter: the model can produce 1.499999, and "one
    # point five times speed" must never be read out as anything stranger.
    speed = round(speed * 4) / 4
    return InterpretResult(
        action=Action.SET_SPEED,
        spoken_response=f"{_spoken_speed(speed)} speed.",
        speed=speed,
    )


def _spoken_speed(speed: float) -> str:
    if speed == 1:
        return "Normal"
    if speed == int(speed):
        return f"{int(speed)} times"
    return f"{speed:g} times"


async def _find_show(query: str, transcript: str, discovery_llm) -> DiscoveredFeed | None:
    """A show or publication by spoken name.

    A spoken domain wins outright: "the RSS feed of astralcodexten.com"
    names a website, and its own feed must be resolved directly — never
    outranked by a similarly-named show in the podcast directory. The
    transcript is checked as well as the model's extracted query, because
    the model sometimes strips the domain down to a bare name. Otherwise:
    the directory first (fast, covers essentially every podcast), then LLM
    web discovery for blogs and newsletters the directory does not know.
    """
    for domain in spoken_domains(f"{transcript} {query}"):
        try:
            feed_url, parsed = await resolve_feed(f"https://{domain}")
        except (FeedFetchError, FeedParseError):
            continue
        return DiscoveredFeed(feed_url=feed_url, title=parsed.title)

    try:
        matches = await search_podcasts(query)
    except PodcastSearchError as exc:
        # The directory being down does not stop web discovery from working.
        logger.warning("podcast search failed for %r: %s", query, exc)
        matches = []
    if matches:
        return DiscoveredFeed(feed_url=matches[0].feed_url, title=matches[0].title)
    return await find_feed_by_name(query, discovery_llm)


async def _subscribe(
    session: AsyncSession, query: str | None, transcript: str, user: User, discovery_llm
) -> InterpretResult:
    """Find a show or publication by spoken name and follow it."""
    if not query or not query.strip():
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Which show would you like to subscribe to?",
        )

    found = await _find_show(query, transcript, discovery_llm)
    if found is None:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I could not find a podcast or publication called {query}.",
        )

    try:
        await feed_service.subscribe(session, found.feed_url, user)
    except AlreadySubscribedError:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"You are already subscribed to {found.title}.",
        )
    except (FeedFetchError, FeedParseError) as exc:
        logger.warning("could not subscribe to %s: %s", found.feed_url, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I found {found.title}, but could not load its episodes.",
        )

    return InterpretResult(
        action=Action.SUBSCRIBED,
        spoken_response=f"Subscribed to {found.title}.",
    )


async def _play_from_show(
    session: AsyncSession,
    llm,
    transcript: str,
    show_query: str | None,
    episode_query: str | None,
    discovery_llm,
) -> InterpretResult:
    """Play an episode of a show she is not subscribed to.

    The show is found in the directory (or, for a publication the directory
    does not know, by web discovery) and ingested into the shared catalog —
    but not subscribed to: asking to hear one episode is not asking to follow
    the show. The common case ("the latest X") is resolved here without a
    second model call; only a described episode needs the model again, and
    then it only reads this one show's episodes.
    """
    if not show_query or not show_query.strip():
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Which show would you like to hear?",
        )

    found = await _find_show(show_query, transcript, discovery_llm)
    if found is None:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I could not find a podcast or publication called {show_query}.",
        )

    try:
        feed = await feed_service.ensure_feed(session, found.feed_url)
    except (FeedFetchError, FeedParseError) as exc:
        logger.warning("could not load feed %s: %s", found.feed_url, exc)
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"I found {found.title}, but could not load its episodes.",
        )

    candidates = await feed_candidates(session, feed.id)
    if not candidates:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=f"{feed.title} has no episodes I can play.",
        )

    if _wants_latest(episode_query):
        episode = await session.get(Episode, candidates[0].id, options=[joinedload(Episode.feed)])
        return InterpretResult(
            action=Action.PLAY_EPISODE,
            spoken_response=f"Playing the latest {feed.title}.",
            episode=episode,
        )

    raw = await llm.decide(
        system=EPISODE_PICK_PROMPT,
        user=build_prompt(transcript, candidates),
        output_model=ModelDecision,
    )
    try:
        decision = ModelDecision.model_validate(raw)
    except ValidationError as exc:
        logger.warning("model returned an unusable episode pick (%s): %r", exc, raw)
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    if decision.action is not Action.PLAY_EPISODE or decision.episode_id not in {
        candidate.id for candidate in candidates
    }:
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response=decision.spoken_response
            or f"I could not find that episode of {feed.title}.",
        )

    episode = await session.get(Episode, decision.episode_id, options=[joinedload(Episode.feed)])
    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


def _wants_latest(episode_query: str | None) -> bool:
    """Does the episode description just mean "the newest one"?

    Resolving this here saves a second model call for the most common request
    by far. Anything more specific goes to the model.
    """
    if episode_query is None:
        return True
    words = set(re.sub(r"[^a-z0-9 ]", " ", episode_query.casefold()).split())
    words -= {"the", "one", "episode", "show", "of", "their", "her", "his"}
    return not words or words <= {"latest", "newest", "most", "recent", "new", "last"}


async def _unsubscribe(session: AsyncSession, query: str | None, user: User) -> InterpretResult:
    """Stop following a show she already has."""
    if not query or not query.strip():
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="Which show would you like to remove?",
        )

    feeds = (
        await session.scalars(
            select(Feed)
            .join(Subscription, Subscription.feed_id == Feed.id)
            .where(Subscription.user_id == user.id)
        )
    ).all()
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
    # Only this user's subscription goes; the feed and its episodes stay in
    # the shared catalog for other subscribers.
    await feed_service.unsubscribe(session, feed.id, user)
    return InterpretResult(
        action=Action.UNSUBSCRIBED,
        spoken_response=f"Unsubscribed from {title}.",
    )


_CLARIFY = "Sorry, I did not catch which episode you meant. Could you say that again?"
