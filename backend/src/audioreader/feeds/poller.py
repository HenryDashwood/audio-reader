"""Re-fetch subscribed feeds and store episodes that appeared since last poll."""

import logging
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.fetcher import FeedFetchError, fetch_feed_bytes
from audioreader.feeds.parser import FeedParseError, parse_feed
from audioreader.feeds.service import apply_feed_metadata, new_episodes
from audioreader.models import Episode, Feed, Subscription

logger = logging.getLogger(__name__)


@dataclass
class PollSummary:
    polled: int = 0
    failed: int = 0
    episodes_added: int = 0


async def poll_feed(session: AsyncSession, feed: Feed) -> int:
    """Fetch one feed and store its new episodes. Returns how many were added."""
    parsed = parse_feed(await fetch_feed_bytes(feed.url))
    known_guids = set(await session.scalars(select(Episode.guid).where(Episode.feed_id == feed.id)))
    episodes = new_episodes(parsed, known_guids)
    for episode in episodes:
        episode.feed_id = feed.id
    session.add_all(episodes)
    apply_feed_metadata(feed, parsed)
    await session.commit()
    return len(episodes)


async def poll_all_feeds(session: AsyncSession) -> PollSummary:
    """Poll every feed; one broken feed must never block the rest."""
    summary = PollSummary()
    # Iterate over plain ids, not ORM objects: a rollback for one broken feed
    # expires every object the session has loaded, so each iteration loads its
    # feed fresh instead of trusting objects fetched before the loop.
    # Only feeds somebody still subscribes to: unsubscribing leaves the feed
    # in the catalog, and polling those orphans forever would be wasted work.
    feed_ids = (
        await session.scalars(select(Feed.id).where(Feed.id.in_(select(Subscription.feed_id))))
    ).all()
    for feed_id in feed_ids:
        feed = await session.get(Feed, feed_id)
        if feed is None:
            continue
        feed_url = feed.url
        try:
            summary.episodes_added += await poll_feed(session, feed)
            summary.polled += 1
        except (FeedFetchError, FeedParseError) as exc:
            await session.rollback()
            summary.failed += 1
            logger.warning("poll failed for feed %s (%s): %s", feed_id, feed_url, exc)
    return summary


if __name__ == "__main__":
    # One-shot poll pass, for manual runs and external schedulers:
    #   uv run python -m audioreader.feeds.poller
    import asyncio

    from audioreader.db import SessionMaker

    async def _main() -> None:
        logging.basicConfig(level=logging.INFO)
        async with SessionMaker() as session:
            result = await poll_all_feeds(session)
        print(result)

    asyncio.run(_main())
