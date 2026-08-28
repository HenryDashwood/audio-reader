from urllib.parse import urljoin, urlsplit

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.artwork import site_artwork_is_due, website_artwork_url
from audioreader.feeds.discovery import resolve_feed
from audioreader.feeds.parser import ParsedFeed
from audioreader.models import Episode, Feed, FeedAlias, Subscription, User, utcnow


class AlreadySubscribedError(Exception):
    pass


async def ensure_feed(session: AsyncSession, url: str) -> Feed:
    """Get a feed into the shared catalog without following it.

    A feed already in the catalog is not re-fetched: the poller keeps it
    current. This is what lets a show be previewed or played before anyone
    subscribes to it. The URL need not be the feed itself — a homepage is
    resolved to its advertised feed, and the feed is stored under the
    resolved URL so both routes lead to one catalog entry."""
    feed = await _feed_for_url(session, url)
    if feed is not None:
        if await _backfill_site_artwork(feed):
            await session.commit()
        return feed
    resolved_url, parsed = await resolve_feed(url)
    aliases = {url}
    if parsed.self_url:
        aliases.add(urljoin(resolved_url, parsed.self_url))
    feed = await _feed_for_url(session, resolved_url)
    if feed is not None:
        changed = await _remember_aliases(session, feed, aliases)
        if await _backfill_site_artwork(feed):
            changed = True
        if changed:
            await session.commit()
        return feed
    feed = Feed(url=resolved_url, title=parsed.title)
    apply_feed_metadata(feed, parsed)
    feed.episodes.extend(new_episodes(parsed, known_guids=set()))
    session.add(feed)
    await session.flush()
    await _remember_aliases(session, feed, aliases)
    await session.commit()
    return feed


async def _backfill_site_artwork(feed: Feed) -> bool:
    """Upgrade an older catalog row without re-fetching its full feed.

    Preview-only feeds are intentionally absent from the background poller,
    but reopening one is still an opportunity to fill artwork introduced by a
    newer backend release. The timestamp makes this a one-off bounded fetch,
    with an occasional retry for sites that were temporarily unavailable.
    """

    if feed.image_url or feed.site_image_url or not site_artwork_is_due(feed.site_artwork_checked_at):
        return False
    feed.site_image_url = await website_artwork_url(feed.site_url, feed.url)
    feed.site_artwork_checked_at = utcnow()
    return True


async def _feed_for_url(session: AsyncSession, url: str) -> Feed | None:
    feed = await session.scalar(select(Feed).where(Feed.url == url))
    if feed is not None:
        return feed
    return await session.scalar(select(Feed).join(FeedAlias).where(FeedAlias.url == url))


async def _remember_aliases(session: AsyncSession, feed: Feed, urls: set[str]) -> bool:
    """Record safe alternate URLs without stealing one from another feed."""

    changed = False
    for alias in urls:
        try:
            parsed = urlsplit(alias)
            port = parsed.port
        except ValueError:
            continue
        if (
            alias == feed.url
            or parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or port not in {None, 80, 443}
            or await _feed_for_url(session, alias) is not None
        ):
            continue
        session.add(FeedAlias(url=alias, feed_id=feed.id))
        changed = True
    return changed


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
    # Following a show starts an inbox for what arrives next. Its existing
    # catalogue remains browsable and searchable, but subscribing must not
    # turn years of history into dozens of allegedly new items.
    latest_episode_id = await session.scalar(
        select(func.max(Episode.id)).where(Episode.feed_id == feed.id)
    )
    session.add(
        Subscription(
            user_id=user.id,
            feed=feed,
            latest_after_episode_id=latest_episode_id,
        )
    )
    await session.commit()
    return feed


async def clear_latest(session: AsyncSession, user: User) -> None:
    """Advance every subscribed show's inbox cursor to its current end.

    Nothing is marked heard or deleted: the show's page and full-library
    search still contain every episode, and subsequent ingests have higher
    ids so they appear in Latest normally.
    """
    subscriptions = list(
        await session.scalars(select(Subscription).where(Subscription.user_id == user.id))
    )
    if not subscriptions:
        return
    latest_rows = await session.execute(
        select(Episode.feed_id, func.max(Episode.id))
        .where(Episode.feed_id.in_([subscription.feed_id for subscription in subscriptions]))
        .group_by(Episode.feed_id)
    )
    latest_by_feed = {
        feed_id: latest_episode_id
        for feed_id, latest_episode_id in latest_rows.tuples()
    }
    for subscription in subscriptions:
        subscription.latest_after_episode_id = latest_by_feed.get(subscription.feed_id)
    await session.commit()


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
    site_changed = parsed.site_url != feed.site_url
    feed.title = parsed.title
    feed.description = parsed.description
    feed.image_url = parsed.image_url
    feed.site_url = parsed.site_url
    if parsed.site_artwork_checked:
        feed.site_image_url = parsed.site_artwork_url
        feed.site_artwork_checked_at = utcnow()
    elif site_changed:
        # Artwork belonging to an old homepage must not leak into a feed that
        # has moved. It will be rediscovered if the declared feed image goes.
        feed.site_image_url = None
        feed.site_artwork_checked_at = None
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
                author=item.author,
                audio_url=item.audio_url,
                duration_seconds=item.duration_seconds,
                published_at=item.published_at,
                link=item.link,
                image_url=item.image_url,
            )
        )
    return episodes
