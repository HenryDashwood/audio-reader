"""Re-fetch subscribed feeds and store episodes that appeared since last poll."""

import contextlib
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import delete, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds.fetcher import FeedFetchError, fetch_feed_bytes
from audioreader.feeds.parser import FeedParseError, parse_feed
from audioreader.feeds.service import apply_feed_metadata, new_episodes
from audioreader.models import Episode, Feed, PlaybackPosition, Subscription, utcnow

logger = logging.getLogger(__name__)

#: Arbitrary but fixed: Postgres advisory locks are keyed by a bare integer, so
#: the only requirement is that nothing else in this database picks the same one.
POLL_LOCK_KEY = 0x4155_4449  # "AUDI"


async def poll_feed(session: AsyncSession, feed: Feed) -> int:
    """Fetch one feed and store its new episodes. Returns how many were added."""
    parsed = parse_feed(await fetch_feed_bytes(feed.url))
    known_guids = set(await session.scalars(select(Episode.guid).where(Episode.feed_id == feed.id)))
    episodes = new_episodes(parsed, known_guids)
    for episode in episodes:
        episode.feed_id = feed.id
    session.add_all(episodes)
    apply_feed_metadata(feed, parsed)
    feed.consecutive_failures = 0
    feed.last_error = None
    await session.commit()
    return len(episodes)


@dataclass
class PollSummary:
    polled: int = 0
    failed: int = 0
    episodes_added: int = 0
    #: Feeds that have now failed enough times in a row to be worth reporting.
    failing: tuple[str, ...] = ()


@contextlib.asynccontextmanager
async def poll_lock(session: AsyncSession) -> AsyncIterator[bool]:
    """Hold the cluster-wide right to run a poll pass, if this is Postgres.

    The poller lives inside the web process, so two replicas would otherwise
    both wake on the same interval and fetch every feed twice — doubling the
    load we put on other people's servers for nothing. A Postgres advisory
    lock is the cheapest fix that needs no new infrastructure.

    On SQLite (tests, and any single-process run) there is nothing to
    coordinate, so the lock is granted unconditionally.
    """
    if session.bind.dialect.name != "postgresql":
        yield True
        return

    acquired = bool(await session.scalar(text("SELECT pg_try_advisory_lock(:key)"), {"key": POLL_LOCK_KEY}))
    try:
        yield acquired
    finally:
        if acquired:
            await session.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": POLL_LOCK_KEY})


async def poll_all_feeds(session: AsyncSession) -> PollSummary:
    """Poll every feed; one broken feed must never block the rest."""
    summary = PollSummary()
    # Iterate over plain ids, not ORM objects: a rollback for one broken feed
    # expires every object the session has loaded, so each iteration loads its
    # feed fresh instead of trusting objects fetched before the loop.
    # Only feeds somebody still subscribes to: unsubscribing leaves the feed
    # in the catalog, and polling those orphans forever would be wasted work.
    feed_ids = (await session.scalars(select(Feed.id).where(Feed.id.in_(select(Subscription.feed_id))))).all()
    failing = []
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
            # Reloaded after the rollback expired it, then counted: a feed
            # that has moved or shut down should become visible rather than
            # quietly never producing another episode.
            feed = await session.get(Feed, feed_id)
            if feed is not None:
                feed.consecutive_failures += 1
                feed.last_error = str(exc)[:500]
                await session.commit()
                if feed.consecutive_failures >= settings.feed_failure_threshold:
                    failing.append(feed.title)
                    logger.error(
                        "feed %s (%s) has failed %d polls in a row: %s",
                        feed_id,
                        feed_url,
                        feed.consecutive_failures,
                        exc,
                    )
                    continue
            logger.warning("poll failed for feed %s (%s): %s", feed_id, feed_url, exc)
    summary.failing = tuple(failing)
    return summary


async def prune_orphaned_feeds(session: AsyncSession, now: datetime | None = None) -> int:
    """Delete catalog entries nobody has any use for. Returns how many went.

    Previewing a show, or asking to hear one episode of something without
    following it, puts a feed and all its episodes into the shared catalog.
    Most of those are never touched again, and article text is stored in full,
    so left alone the catalog grows without limit on behalf of nobody.

    A feed is only removed when all three are true: nobody subscribes to it,
    nobody has a playback position anywhere in it, and it has been sitting
    there long enough that it is clearly not part of a session in progress.
    That last condition is what makes this safe to run on a timer — a feed
    previewed thirty seconds ago is never a candidate.
    """
    now = now or utcnow()
    cutoff = now - timedelta(days=settings.orphan_feed_retention_days)

    orphans = (
        await session.scalars(
            select(Feed.id)
            .where(
                Feed.id.not_in(select(Subscription.feed_id)),
                Feed.id.not_in(
                    select(Episode.feed_id).join(PlaybackPosition, PlaybackPosition.episode_id == Episode.id)
                ),
                Feed.created_at < cutoff,
            )
            .limit(settings.orphan_prune_batch_size)
        )
    ).all()
    if not orphans:
        return 0

    # Episodes explicitly, then the feed: the cascade exists, but leaning on it
    # would mean the tests pass on SQLite while proving nothing.
    await session.execute(delete(Episode).where(Episode.feed_id.in_(orphans)))
    await session.execute(delete(Feed).where(Feed.id.in_(orphans)))
    await session.commit()
    logger.info("pruned %d orphaned feeds from the catalog", len(orphans))
    return len(orphans)


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
