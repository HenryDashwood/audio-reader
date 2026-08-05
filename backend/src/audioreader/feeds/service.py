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
    feed = Feed(url=url, title=parsed.title)
    apply_feed_metadata(feed, parsed)
    feed.episodes.extend(new_episodes(parsed, known_guids=set()))
    session.add(feed)
    await session.commit()
    return feed


def apply_feed_metadata(feed: Feed, parsed: ParsedFeed) -> None:
    """Feed-level fields can change between polls (title, artwork, blurb)."""
    feed.title = parsed.title
    feed.description = parsed.description
    feed.image_url = parsed.image_url
    feed.site_url = parsed.site_url
    feed.last_polled_at = utcnow()


def new_episodes(parsed: ParsedFeed, known_guids: set[str]) -> list[Episode]:
    """Build Episode rows for items we have not stored yet.

    Tracks guids as it goes so a feed document that repeats a guid cannot
    produce two rows and trip the (feed_id, guid) unique constraint.
    """
    seen = set(known_guids)
    episodes: list[Episode] = []
    for item in parsed.items:
        if item.guid in seen:
            continue
        seen.add(item.guid)
        episodes.append(
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
    return episodes
