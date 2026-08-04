from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.fetcher import fetch_feed_bytes
from audioreader.feeds.parser import ParsedFeed, parse_feed
from audioreader.models import Episode, Feed, utcnow


class AlreadySubscribedError(Exception):
    pass


async def subscribe(session: AsyncSession, url: str) -> Feed:
    existing = await session.scalar(select(Feed).where(Feed.url == url))
    if existing is not None:
        raise AlreadySubscribedError(url)

    parsed = parse_feed(await fetch_feed_bytes(url))
    feed = Feed(
        url=url,
        title=parsed.title,
        description=parsed.description,
        image_url=parsed.image_url,
        site_url=parsed.site_url,
        last_polled_at=utcnow(),
    )
    session.add(feed)
    _add_new_episodes(feed, parsed, known_guids=set())
    await session.commit()
    return feed


def _add_new_episodes(feed: Feed, parsed: ParsedFeed, known_guids: set[str]) -> int:
    """Attach items not already stored. Shared by subscribe and (later) the poller."""
    added = 0
    for item in parsed.items:
        if item.guid in known_guids:
            continue
        feed.episodes.append(
            Episode(
                guid=item.guid,
                title=item.title,
                description=item.description,
                content_html=item.content_html,
                audio_url=item.audio_url,
                duration_seconds=item.duration_seconds,
                published_at=item.published_at,
                link=item.link,
            )
        )
        added += 1
    return added
