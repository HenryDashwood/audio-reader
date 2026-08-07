from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.db import get_session
from audioreader.feeds import service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.models import Episode, Feed
from audioreader.schemas import EpisodeRead, FeedCreate, FeedRead

router = APIRouter(prefix="/feeds", tags=["feeds"])

Session = Annotated[AsyncSession, Depends(get_session)]


def _to_feed_read(feed: Feed, episode_count: int) -> FeedRead:
    return FeedRead(
        id=feed.id,
        url=feed.url,
        title=feed.title,
        description=feed.description,
        image_url=feed.image_url,
        episode_count=episode_count,
    )


@router.post("", status_code=201)
async def subscribe(body: FeedCreate, session: Session) -> FeedRead:
    try:
        feed = await service.subscribe(session, str(body.url))
    except service.AlreadySubscribedError as exc:
        raise HTTPException(status_code=409, detail="already subscribed to this feed") from exc
    except FeedFetchError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except FeedParseError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return _to_feed_read(feed, episode_count=len(feed.episodes))


@router.get("")
async def list_feeds(session: Session) -> list[FeedRead]:
    counts = (
        select(Episode.feed_id, func.count(Episode.id).label("count"))
        .group_by(Episode.feed_id)
        .subquery()
    )
    rows = await session.execute(
        select(Feed, func.coalesce(counts.c.count, 0))
        .outerjoin(counts, counts.c.feed_id == Feed.id)
        .order_by(Feed.title)
    )
    return [_to_feed_read(feed, count) for feed, count in rows.all()]


@router.get("/{feed_id}/episodes")
async def list_episodes(feed_id: int, session: Session, limit: int = 50) -> list[EpisodeRead]:
    feed = await session.get(Feed, feed_id)
    if feed is None:
        raise HTTPException(status_code=404, detail="feed not found")
    episodes = await session.scalars(
        select(Episode)
        .where(Episode.feed_id == feed_id)
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return [EpisodeRead.model_validate(episode) for episode in episodes]


episodes_router = APIRouter(prefix="/episodes", tags=["episodes"])


@episodes_router.get("")
async def recent_episodes(session: Session, limit: int = 30) -> list[EpisodeRead]:
    """Newest playable episodes across every subscription.

    Siri needs a concrete list of episodes up front: its App Shortcut phrases
    match spoken words against suggested entities, not against free text.
    """
    episodes = await session.scalars(
        select(Episode)
        .where(Episode.audio_url.is_not(None))
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return [EpisodeRead.model_validate(episode) for episode in episodes]


@episodes_router.get("/{episode_id}")
async def get_episode(episode_id: int, session: Session) -> EpisodeRead:
    """Fetch one episode. Siri uses this to restore an entity it resolved
    earlier, so it must work without any of the surrounding context."""
    episode = await session.get(Episode, episode_id)
    if episode is None:
        raise HTTPException(status_code=404, detail="episode not found")
    return EpisodeRead.model_validate(episode)
