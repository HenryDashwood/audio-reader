from collections.abc import Sequence
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader import episode_search, positions
from audioreader.auth.dependencies import get_current_user
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.feeds import articles, service
from audioreader.feeds.discovery import find_feed_by_name
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, search_podcasts
from audioreader.llm.client import LLMClient
from audioreader.llm.provider import get_discovery_llm_client
from audioreader.models import PLAYABLE_EPISODE, Episode, Feed, Subscription, User
from audioreader.ratelimit import SlidingWindow
from audioreader.routers.auth import has_current_ai_data_sharing_consent
from audioreader.schemas import (
    EpisodeRead,
    EpisodeStateUpdate,
    EpisodeTextRead,
    FeedCreate,
    FeedPreview,
    FeedRead,
    PodcastSearchResult,
    PositionUpdate,
    PublicationSearchRequest,
    secure_url,
)

router = APIRouter(prefix="/feeds", tags=["feeds"])

Session = Annotated[AsyncSession, Depends(get_session)]
CurrentUser = Annotated[User, Depends(get_current_user)]
DiscoveryLLM = Annotated[LLMClient, Depends(get_discovery_llm_client)]

_feed_operation_limit = SlidingWindow(settings.feed_operation_rate_limit_per_minute, window_seconds=60)
_podcast_search_limit = SlidingWindow(settings.podcast_search_rate_limit_per_minute, window_seconds=60)


def _check_limit(window: SlidingWindow, user: User, message: str) -> None:
    if window.limit <= 0:
        return
    decision = window.check(str(user.id))
    if not decision.allowed:
        raise HTTPException(
            status_code=429,
            detail={"spoken_response": message},
            headers={"Retry-After": str(decision.retry_after)},
        )
    window.prune()


def check_feed_operation_limit(user: CurrentUser) -> None:
    _check_limit(
        _feed_operation_limit,
        user,
        "You have checked several publications very quickly. Please wait a moment and try again.",
    )


def check_podcast_search_limit(user: CurrentUser) -> None:
    _check_limit(
        _podcast_search_limit,
        user,
        "You have searched several times very quickly. Please wait a moment and try again.",
    )


def _to_feed_read(feed: Feed, episode_count: int, audio_count: int) -> FeedRead:
    return FeedRead(
        id=feed.id,
        url=feed.url,
        title=feed.title,
        description=feed.description,
        image_url=feed.image_url,
        episode_count=episode_count,
        # An empty feed is left as a podcast: "0 posts" for a show whose
        # episodes simply have not loaded yet would be a worse guess than the
        # default, and the label corrects itself on the next refresh.
        is_article_feed=episode_count > 0 and audio_count == 0,
        is_failing=feed.consecutive_failures >= settings.feed_failure_threshold,
    )


async def _counts_for(session: AsyncSession, feed_id: int) -> tuple[int, int]:
    """How many items the feed has, and how many of them carry audio.

    Counted with a query, never len(feed.episodes): the collection is only
    reliably in memory when the feed was created this request, and a lazy load
    outside the session's greenlet is an error, not a query.
    """
    row = (
        await session.execute(
            # count(column) counts non-null values, which is exactly the
            # number of items with audio.
            select(func.count(Episode.id), func.count(Episode.audio_url)).where(Episode.feed_id == feed_id)
        )
    ).one()
    return row[0] or 0, row[1] or 0


async def episodes_read(session: AsyncSession, user: User, episodes: Sequence[Episode]) -> list[EpisodeRead]:
    """Episode payloads with the user's playback position and artwork folded in.

    Callers must load each episode's feed eagerly (joinedload): the artwork
    fallback reads episode.feed, and a lazy load inside an async request is an
    error, not a query.
    """
    stored = await positions.positions_for(session, user, (episode.id for episode in episodes))
    reads = []
    for episode in episodes:
        read = EpisodeRead.model_validate(episode)
        read.feed_title = episode.feed.title
        # Item-level artwork is the exception; most feeds only set show art.
        read.image_url = secure_url(episode.image_url or episode.feed.image_url)
        # Mirrors the fallback chain in feeds/articles.py: anything that can
        # yield text marks the episode readable, so articles are playable.
        read.has_text = bool(episode.article_text or episode.content_html or episode.link or episode.description)
        if (position := stored.get(episode.id)) is not None:
            read.position_seconds = position.position_seconds
            read.completed = position.completed
            read.dismissed = position.dismissed
        reads.append(read)
    return reads


@router.post("", status_code=201, dependencies=[Depends(check_feed_operation_limit)])
async def subscribe(body: FeedCreate, session: Session, user: CurrentUser) -> FeedRead:
    try:
        feed = await service.subscribe(session, str(body.url), user)
    except service.AlreadySubscribedError as exc:
        raise HTTPException(status_code=409, detail="already subscribed to this feed") from exc
    except FeedFetchError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except FeedParseError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    count, audio_count = await _counts_for(session, feed.id)
    return _to_feed_read(feed, episode_count=count, audio_count=audio_count)


@router.post("/preview", dependencies=[Depends(check_feed_operation_limit)])
async def preview(body: FeedCreate, session: Session, user: CurrentUser) -> FeedPreview:
    """A show's page before subscribing: ingest the feed into the shared
    catalog (without following it) so its episodes have real ids and can be
    played, resumed, and subscribed to instantly."""
    try:
        feed = await service.ensure_feed(session, str(body.url))
    except FeedFetchError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except FeedParseError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    episode_count, audio_count = await _counts_for(session, feed.id)
    episodes = (
        await session.scalars(
            select(Episode)
            .options(joinedload(Episode.feed))
            .where(Episode.feed_id == feed.id)
            .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
            .limit(50)
        )
    ).all()
    return FeedPreview(
        feed=_to_feed_read(feed, episode_count=episode_count, audio_count=audio_count),
        episodes=await episodes_read(session, user, episodes),
        subscribed=await service.is_subscribed(session, feed.id, user),
    )


@router.get("")
async def list_feeds(session: Session, user: CurrentUser) -> list[FeedRead]:
    counts = (
        select(
            Episode.feed_id,
            func.count(Episode.id).label("count"),
            func.count(Episode.audio_url).label("audio_count"),
        )
        .group_by(Episode.feed_id)
        .subquery()
    )
    rows = await session.execute(
        select(Feed, func.coalesce(counts.c.count, 0), func.coalesce(counts.c.audio_count, 0))
        .join(Subscription, Subscription.feed_id == Feed.id)
        .where(Subscription.user_id == user.id)
        .outerjoin(counts, counts.c.feed_id == Feed.id)
        .order_by(Feed.title)
    )
    return [_to_feed_read(feed, count, audio_count) for feed, count, audio_count in rows.all()]


@router.delete("/{feed_id}", status_code=204)
async def unsubscribe(feed_id: int, session: Session, user: CurrentUser) -> None:
    feed = await service.unsubscribe(session, feed_id, user)
    if feed is None:
        raise HTTPException(status_code=404, detail="not subscribed to this feed")


@router.get("/{feed_id}/episodes")
async def list_episodes(
    feed_id: int,
    session: Session,
    user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> list[EpisodeRead]:
    """A show's episodes, newest first — or the ones matching `q`.

    Searching is done here rather than in the app because the app only ever
    holds the newest fifty. A feed like In Our Time carries its whole archive,
    so filtering what was already downloaded would search a couple of months
    of a programme that has been running since 1998 — and would find nothing
    while looking exactly like an answer.
    """
    subscribed = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
    )
    if subscribed is None:
        raise HTTPException(status_code=404, detail="feed not found")
    statement = (
        select(Episode)
        .options(joinedload(Episode.feed))
        .where(Episode.feed_id == feed_id)
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    if q and q.strip():
        statement = episode_search.matching(q, statement)
    episodes = (await session.scalars(statement)).all()
    return await episodes_read(session, user, episodes)


search_router = APIRouter(prefix="/search", tags=["search"])


@search_router.get(
    "/podcasts",
    dependencies=[Depends(check_podcast_search_limit)],
    response_model_exclude_none=True,
)
async def search_directory(
    q: Annotated[str, Query(max_length=200)],
    user: CurrentUser,
    country: Annotated[str | None, Query(min_length=2, max_length=2)] = None,
) -> list[PodcastSearchResult]:
    """Typed search against the public podcast directory.

    Unlike the voice path, no relevance guard: the results are on screen, so
    loose matches help rather than mislead.
    """
    query = q.strip()
    if not query:
        return []
    try:
        matches = await search_podcasts(query, limit=25, strict=False, country=country)
    except PodcastSearchError as exc:
        raise HTTPException(
            status_code=502,
            detail={"spoken_response": "The podcast directory is unavailable right now. Please try again shortly."},
        ) from exc
    return [PodcastSearchResult(**match.model_dump()) for match in matches]


@search_router.get("/episodes")
async def search_library_episodes(
    q: Annotated[str, Query(max_length=200)],
    session: Session,
    user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=100)] = 25,
) -> list[EpisodeRead]:
    """Search every playable item in this listener's subscriptions.

    This is the visual counterpart of the existing voice candidate search:
    it searches the whole stored back catalogue rather than whichever fifty
    items happen to be on the phone.
    """

    query = q.strip()
    if not query:
        return []
    statement = (
        select(Episode)
        .join(Subscription, Subscription.feed_id == Episode.feed_id)
        .options(joinedload(Episode.feed))
        .where(Subscription.user_id == user.id, PLAYABLE_EPISODE)
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    episodes = (await session.scalars(episode_search.matching(query, statement))).all()
    return await episodes_read(session, user, episodes)


@search_router.post("/publications", dependencies=[Depends(check_feed_operation_limit)])
async def search_publication_on_web(
    body: PublicationSearchRequest,
    discovery_llm: DiscoveryLLM,
    user: CurrentUser,
) -> PodcastSearchResult | None:
    """Explicit AI-assisted fallback for a publication absent from directories."""

    if not has_current_ai_data_sharing_consent(user):
        raise HTTPException(
            status_code=403,
            detail={"spoken_response": ("Before searching the web with AI, allow AI data sharing in Hearful.")},
        )
    found = await find_feed_by_name(body.query, discovery_llm)
    if found is None:
        return None
    return PodcastSearchResult(title=found.title, feed_url=found.feed_url)


episodes_router = APIRouter(prefix="/episodes", tags=["episodes"])


@episodes_router.get("")
async def recent_episodes(
    session: Session,
    user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
) -> list[EpisodeRead]:
    """Newest playable items — episodes and articles — across the user's
    subscriptions, minus the ones she has already dealt with.

    Siri needs a concrete list of episodes up front: its App Shortcut phrases
    match spoken words against suggested entities, not against free text.

    Episodes she has heard or put aside are left out here rather than by the
    app, so the same fifty items are worth fifty rows however much of the feed
    she has worked through. They are still reachable on the show's own page,
    and the voice pipeline still offers them, so nothing is lost — only the
    "what's new" list stops repeating itself.
    """
    episodes = (
        await session.scalars(
            select(Episode)
            .options(joinedload(Episode.feed))
            .join(Subscription, Subscription.feed_id == Episode.feed_id)
            .where(
                Subscription.user_id == user.id,
                PLAYABLE_EPISODE,
                Episode.id.not_in(positions.filed_away(user)),
            )
            .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
            .limit(limit)
        )
    ).all()
    return await episodes_read(session, user, episodes)


@episodes_router.get("/{episode_id}")
async def get_episode(episode_id: int, session: Session, user: CurrentUser) -> EpisodeRead:
    """Fetch one episode. Siri uses this to restore an entity it resolved
    earlier, so it must work without any of the surrounding context — the
    user's token is required, but a subscription is deliberately not: the
    entity may be from a feed she has since unsubscribed from."""
    episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    return (await episodes_read(session, user, [episode]))[0]


@episodes_router.get("/{episode_id}/text", dependencies=[Depends(check_feed_operation_limit)])
async def get_episode_text(episode_id: int, session: Session, user: CurrentUser) -> EpisodeTextRead:
    """The full article for a written episode — speech-ready text and the
    sanitised HTML behind it — extracted on first request and cached. Like
    get_episode, a subscription is deliberately not required: articles can be
    played from previews and old voice picks."""
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    text, html = await articles.content_for(session, episode)
    if not text:
        raise HTTPException(
            status_code=422,
            detail={"spoken_response": "Sorry, I could not get the text of that article."},
        )
    return EpisodeTextRead(episode_id=episode.id, title=episode.title, text=text, html=html)


@episodes_router.put("/{episode_id}/state", status_code=204)
async def put_state(episode_id: int, body: EpisodeStateUpdate, session: Session, user: CurrentUser) -> None:
    """Mark an episode played, put it aside, or put it back.

    Separate from the position endpoint, which fires from a heartbeat every
    thirty seconds: a deliberate "I have heard this" must not be something a
    later tick can quietly undo.
    """
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    await positions.set_episode_state(session, user, episode_id, played=body.played, dismissed=body.dismissed)


@episodes_router.put("/{episode_id}/position", status_code=204)
async def put_position(episode_id: int, body: PositionUpdate, session: Session, user: CurrentUser) -> None:
    """Record where the user is in an episode. Last write wins."""
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    await positions.upsert_position(session, user, episode_id, body.position_seconds, body.completed)
