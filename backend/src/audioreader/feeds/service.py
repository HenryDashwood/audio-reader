from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.discovery import resolve_feed
from audioreader.feeds.parser import ParsedFeed
from audioreader.models import Episode, Feed, Subscription, User, utcnow


class AlreadySubscribedError(Exception):
    pass


async def ensure_feed(session: AsyncSession, url: str) -> Feed:
    """Get a feed into the shared catalog without following it.

    A feed already in the catalog is not re-fetched: the poller keeps it
    current. This is what lets a show be previewed or played before anyone
    subscribes to it. The URL need not be the feed itself — a homepage is
    resolved to its advertised feed, and the feed is stored under the
    resolved URL so both routes lead to one catalog entry."""
    feed = await session.scalar(select(Feed).where(Feed.url == url))
    if feed is not None:
        return feed
    resolved_url, parsed = await resolve_feed(url)
    if resolved_url != url:
        feed = await session.scalar(select(Feed).where(Feed.url == resolved_url))
        if feed is not None:
            return feed
    feed = Feed(url=resolved_url, title=parsed.title)
    apply_feed_metadata(feed, parsed)
    feed.episodes.extend(new_episodes(parsed, known_guids=set()))
    session.add(feed)
    await session.commit()
    return feed


async def is_subscribed(session: AsyncSession, feed_id: int, user: User) -> bool:
    subscription = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
    )
    return subscription is not None


async def subscribe(session: AsyncSession, url: str, user: User) -> Feed:
    """Follow a feed: add it to the shared catalog if it is new, then record
    this user's subscription. A feed another user already follows is not
    re-fetched — only the same user subscribing twice is an error.

    The duplicate check runs after resolution, so subscribing via the
    homepage and via the feed URL count as the same subscription."""
    feed = await ensure_feed(session, url)
    if await is_subscribed(session, feed.id, user):
        raise AlreadySubscribedError(url)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed


async def unsubscribe(session: AsyncSession, feed_id: int, user: User) -> Feed | None:
    """Drop the user's subscription. The feed and its episodes stay in the
    shared catalog for other subscribers (and for instant re-subscribing).
    Returns the feed, or None if the user was not subscribed."""
    subscription = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
    )
    if subscription is None:
        return None
    feed = await session.get(Feed, feed_id)
    await session.delete(subscription)
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
                image_url=item.image_url,
            )
        )
    return episodes
