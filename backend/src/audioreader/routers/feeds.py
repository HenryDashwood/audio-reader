from collections.abc import Sequence
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader import positions
from audioreader.auth.dependencies import get_current_user
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.feeds import articles, service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import PodcastSearchError, search_podcasts
from audioreader.models import PLAYABLE_EPISODE, Episode, Feed, Subscription, User
from audioreader.schemas import (
    EpisodeRead,
    EpisodeTextRead,
    FeedCreate,
    FeedPreview,
    FeedRead,
    PodcastSearchResult,
    PositionUpdate,
    secure_url,
)

router = APIRouter(prefix="/feeds", tags=["feeds"])

Session = Annotated[AsyncSession, Depends(get_session)]
CurrentUser = Annotated[User, Depends(get_current_user)]


def _to_feed_read(feed: Feed, episode_count: int) -> FeedRead:
    return FeedRead(
        id=feed.id,
        url=feed.url,
        title=feed.title,
        description=feed.description,
        image_url=feed.image_url,
        episode_count=episode_count,
        is_failing=feed.consecutive_failures >= settings.feed_failure_threshold,
    )


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
        # Item-level artwork is the exception; most feeds only set show art.
        read.image_url = secure_url(episode.image_url or episode.feed.image_url)
        # Mirrors the fallback chain in feeds/articles.py: anything that can
        # yield text marks the episode readable, so articles are playable.
        read.has_text = bool(episode.article_text or episode.content_html or episode.link or episode.description)
        if (position := stored.get(episode.id)) is not None:
            read.position_seconds = position.position_seconds
            read.completed = position.completed
        reads.append(read)
    return reads


@router.post("", status_code=201)
async def subscribe(body: FeedCreate, session: Session, user: CurrentUser) -> FeedRead:
    try:
        feed = await service.subscribe(session, str(body.url), user)
    except service.AlreadySubscribedError as exc:
        raise HTTPException(status_code=409, detail="already subscribed to this feed") from exc
    except FeedFetchError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except FeedParseError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    # Counted with a query, never len(feed.episodes): the collection is only
    # reliably in memory when the feed was created this request, and a lazy
    # load outside the session's greenlet is an error, not a query.
    count = await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == feed.id))
    return _to_feed_read(feed, episode_count=count or 0)


@router.post("/preview")
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

    episode_count = await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == feed.id))
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
        feed=_to_feed_read(feed, episode_count=episode_count or 0),
        episodes=await episodes_read(session, user, episodes),
        subscribed=await service.is_subscribed(session, feed.id, user),
    )


@router.get("")
async def list_feeds(session: Session, user: CurrentUser) -> list[FeedRead]:
    counts = select(Episode.feed_id, func.count(Episode.id).label("count")).group_by(Episode.feed_id).subquery()
    rows = await session.execute(
        select(Feed, func.coalesce(counts.c.count, 0))
        .join(Subscription, Subscription.feed_id == Feed.id)
        .where(Subscription.user_id == user.id)
        .outerjoin(counts, counts.c.feed_id == Feed.id)
        .order_by(Feed.title)
    )
    return [_to_feed_read(feed, count) for feed, count in rows.all()]


@router.delete("/{feed_id}", status_code=204)
async def unsubscribe(feed_id: int, session: Session, user: CurrentUser) -> None:
    feed = await service.unsubscribe(session, feed_id, user)
    if feed is None:
        raise HTTPException(status_code=404, detail="not subscribed to this feed")


@router.get("/{feed_id}/episodes")
async def list_episodes(feed_id: int, session: Session, user: CurrentUser, limit: int = 50) -> list[EpisodeRead]:
    subscribed = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
    )
    if subscribed is None:
        raise HTTPException(status_code=404, detail="feed not found")
    episodes = (
        await session.scalars(
            select(Episode)
            .options(joinedload(Episode.feed))
            .where(Episode.feed_id == feed_id)
            .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
            .limit(limit)
        )
    ).all()
    return await episodes_read(session, user, episodes)


search_router = APIRouter(prefix="/search", tags=["search"])


@search_router.get("/podcasts")
async def search_directory(q: str, user: CurrentUser) -> list[PodcastSearchResult]:
    """Typed search against the public podcast directory.

    Unlike the voice path, no relevance guard: the results are on screen, so
    loose matches help rather than mislead.
    """
    query = q.strip()
    if not query:
        return []
    try:
        matches = await search_podcasts(query, limit=25, strict=False)
    except PodcastSearchError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return [PodcastSearchResult(**match.model_dump()) for match in matches]


episodes_router = APIRouter(prefix="/episodes", tags=["episodes"])


@episodes_router.get("")
async def recent_episodes(session: Session, user: CurrentUser, limit: int = 30) -> list[EpisodeRead]:
    """Newest playable items — episodes and articles — across the user's
    subscriptions.

    Siri needs a concrete list of episodes up front: its App Shortcut phrases
    match spoken words against suggested entities, not against free text.
    """
    episodes = (
        await session.scalars(
            select(Episode)
            .options(joinedload(Episode.feed))
            .join(Subscription, Subscription.feed_id == Episode.feed_id)
            .where(Subscription.user_id == user.id, PLAYABLE_EPISODE)
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


@episodes_router.get("/{episode_id}/text")
async def get_episode_text(episode_id: int, session: Session, user: CurrentUser) -> EpisodeTextRead:
    """The full article text for a written episode, extracted on first request
    and cached. Like get_episode, a subscription is deliberately not required:
    articles can be played from previews and old voice picks."""
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    text = await articles.text_for(session, episode)
    if not text:
        raise HTTPException(
            status_code=422,
            detail={"spoken_response": "Sorry, I could not get the text of that article."},
        )
    return EpisodeTextRead(episode_id=episode.id, title=episode.title, text=text)


@episodes_router.put("/{episode_id}/position", status_code=204)
async def put_position(episode_id: int, body: PositionUpdate, session: Session, user: CurrentUser) -> None:
    """Record where the user is in an episode. Last write wins."""
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    await positions.upsert_position(session, user, episode_id, body.position_seconds, body.completed)
