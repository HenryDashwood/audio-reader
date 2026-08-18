"""Re-read one feed and update the article markup already stored for it.

The poller only ever adds episodes it has not seen (`new_episodes` skips known
guids), so a publisher who corrects a post leaves the app showing the version
it first fetched, for good. This is the manual remedy: point it at a feed URL
and it refreshes the stored markup for every episode whose content has changed,
then clears the derived article so `articles.content_for` rebuilds it.

Runs where the database is reachable — inside the deployment, or locally
against the dev database:

    python scripts/refresh_feed_content.py https://example.com/feed.xml
    python scripts/refresh_feed_content.py https://example.com/feed.xml --apply

Without `--apply` it reports what it would change and writes nothing.

Episodes are matched by guid, so rows keep their ids and the playback
positions that hang off them. An episode whose *text* changes will shift the
player's estimated timeline under a position saved against the old text, which
is why this is a deliberate act rather than something the poller does.
"""

import argparse
import asyncio
import sys
from urllib.parse import parse_qs, urlsplit, urlunsplit

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine

from audioreader.config import settings
from audioreader.feeds.fetcher import fetch_feed_bytes
from audioreader.feeds.parser import parse_feed
from audioreader.models import Episode, Feed


def engine_for(url: str) -> AsyncEngine:
    """An engine for `url`, whether it points inside the deployment or down a tunnel.

    Postgres URLs from outside carry `sslmode`, which asyncpg does not accept
    as a query parameter — it takes the setting as a connect argument instead.
    A URL without one is left exactly as it is, which is the case inside the
    deployment, where the database is on the private network.
    """
    parts = urlsplit(url)
    modes = parse_qs(parts.query).get("sslmode")
    if not modes:
        return create_async_engine(url)
    stripped = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return create_async_engine(stripped, connect_args={"ssl": modes[0] != "disable"})


def summarise(html: str | None) -> str:
    html = html or ""
    return f"{len(html)} chars, {html.count('<img')} images, {html.count('<figcaption')} captions"


async def refresh(feed_url: str, apply: bool) -> int:
    engine = engine_for(settings.database_url)
    try:
        return await _refresh(engine, feed_url, apply)
    finally:
        await engine.dispose()


async def _refresh(engine: AsyncEngine, feed_url: str, apply: bool) -> int:
    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        feed = await session.scalar(select(Feed).where(Feed.url == feed_url))
        if feed is None:
            print(f"no feed stored under {feed_url}", file=sys.stderr)
            return 1

        stored = await session.scalar(select(func.count(Episode.id)).where(Episode.feed_id == feed.id))
        cached = await session.scalar(
            select(func.count(Episode.id)).where(Episode.feed_id == feed.id, Episode.article_html.is_not(None))
        )
        print(f"feed {feed.id} {feed.title!r}: {stored} episodes stored, {cached} with a cached article")

        parsed = parse_feed(await fetch_feed_bytes(feed.url))
        episodes = (await session.scalars(select(Episode).where(Episode.feed_id == feed.id))).all()
        by_guid = {episode.guid: episode for episode in episodes}

        changed, unknown = [], []
        for item in parsed.items:
            episode = by_guid.get(item.guid)
            if episode is None:
                unknown.append(item.guid)
            elif episode.content_html != item.content_html or episode.description != item.description:
                changed.append((episode, item))

        print(f"feed carries {len(parsed.items)} items; {len(changed)} differ from what is stored")
        for guid in unknown:
            print(f"  not stored yet, left for the poller: {guid}")
        for episode, item in changed:
            print(f"  {episode.title}")
            print(f"      stored: {summarise(episode.content_html)}")
            print(f"      feed:   {summarise(item.content_html)}")

        if not changed:
            return 0
        if not apply:
            print("\ndry run: nothing written. Pass --apply to write these changes.")
            return 0

        for episode, item in changed:
            episode.content_html = item.content_html
            episode.description = item.description
            # Cleared rather than recomputed: content_for derives both on the
            # next read, and does it from the markup it will actually show.
            episode.article_text = None
            episode.article_html = None
        await session.commit()
        print(f"\nupdated {len(changed)} episodes and cleared their cached articles")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("feed_url", help="the feed's URL, exactly as stored in the feeds table")
    parser.add_argument("--apply", action="store_true", help="write the changes (default is a dry run)")
    arguments = parser.parse_args()
    return asyncio.run(refresh(arguments.feed_url, arguments.apply))


if __name__ == "__main__":
    raise SystemExit(main())
