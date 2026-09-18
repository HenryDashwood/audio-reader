"""Import RSS without treating possession of a URL as publication permission."""

import asyncio
import base64
import re
import uuid
from urllib.parse import unquote, urlsplit, urlunsplit

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.discovery import feed_links_in_headers, feed_links_in_html
from audioreader.feeds.fetcher import (
    FEED_ACCEPT,
    MAX_FEED_BYTES,
    MAX_RETRY_DELAY_SECONDS,
    MAX_UPSTREAM_RETRIES,
    FeedFetchError,
    FeedFetchResult,
    _fetch_public_resource,
    fetch_feed_resource,
)
from audioreader.feeds.parser import parse_feed
from audioreader.feeds.service import apply_feed_metadata, new_episodes
from audioreader.models import Episode, Feed


def personalised(url: str) -> bool:
    """Conservative hints only; no hints does NOT mean public."""
    parts = urlsplit(url)
    # Even unknown query keys can be credentials. False positives only make
    # feeds private, never prevent following them.
    return bool(
        parts.username is not None
        or parts.query
        or re.search(
            r"[a-zA-Z0-9_-]{24,}|[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}",
            unquote(parts.netloc + parts.path),
        )
    )


async def fetch_personal_feed(
    url: str,
    *,
    etag: str | None = None,
    last_modified: str | None = None,
    max_retries: int = MAX_UPSTREAM_RETRIES,
    max_retry_delay: float = MAX_RETRY_DELAY_SECONDS,
    wait_out_rate_limits: bool = False,
) -> FeedFetchResult:
    parts = urlsplit(url)
    headers = {"Accept": FEED_ACCEPT}
    if parts.username is not None:
        if parts.scheme != "https":
            raise FeedFetchError("feeds containing credentials require HTTPS")
        credentials = f"{unquote(parts.username)}:{unquote(parts.password or '')}"
        headers["Authorization"] = "Basic " + base64.b64encode(credentials.encode()).decode()
        url = urlunsplit((parts.scheme, parts.netloc.rsplit("@", 1)[-1], parts.path, parts.query, ""))
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    return await _fetch_public_resource(
        url,
        max_bytes=MAX_FEED_BYTES,
        request_headers=headers,
        accept_not_modified=bool(etag or last_modified),
        max_retries=max_retries,
        max_retry_delay=max_retry_delay,
        wait_out_rate_limits=wait_out_rate_limits,
    )


async def advertised_publicly(url: str, fetched: FeedFetchResult) -> bool:
    # Redirect targets and rel=self can discard personal credentials or name a
    # public teaser feed. Never use either as evidence to publish private data.
    if personalised(url) or fetched.final_url != url:
        return False
    parts = urlsplit(url)
    homepage = urlunsplit((parts.scheme, parts.netloc, "/", "", ""))
    if homepage == url:
        return False
    try:
        async with asyncio.timeout(8):
            page = await fetch_feed_resource(homepage)
        if page.content is None or urlsplit(page.final_url).netloc != parts.netloc:
            return False
        links = feed_links_in_html(page.content.decode("utf-8", errors="replace"), page.final_url)
        links += [link.url for link in feed_links_in_headers(page.link_headers, page.final_url)]
        return url in links
    except (FeedFetchError, TimeoutError):
        # A blocked or unavailable homepage must not block the import.
        return False


async def ensure_import_feed(session: AsyncSession, url: str, owner: uuid.UUID) -> Feed:
    existing = await session.scalar(select(Feed).where(Feed.owner_user_id == owner, Feed.private_fetch_url == url))
    if existing is not None:
        from audioreader.feeds.poller import refresh_stale_feed

        await refresh_stale_feed(session, existing)
        return existing
    fetched = await fetch_personal_feed(url)
    if fetched.content is None:
        raise FeedFetchError("the server returned no content")
    parsed = parse_feed(fetched.content)
    public = await advertised_publicly(url, fetched)
    if public:
        # Exact URL only. An alias or a publisher's self URL cannot change scope.
        existing = await session.scalar(select(Feed).where(Feed.url == url, Feed.owner_user_id.is_(None)))
        if existing is not None:
            # Bring the archive current before setting a new follower's Latest
            # watermark. Use the already fetched, publicly verified body.
            from audioreader.saved import reconcile

            await session.refresh(existing, with_for_update=True)
            known = set(await session.scalars(select(Episode.guid).where(Episode.feed_id == existing.id)))
            for episode in await reconcile(session, new_episodes(parsed, known)):
                episode.feed_id = existing.id
                session.add(episode)
            apply_feed_metadata(existing, parsed)
            await session.commit()
            return existing
    feed = Feed(
        url=url if public else f"private-rss:{uuid.uuid4()}",
        private_fetch_url=None if public else url,
        owner_user_id=None if public else owner,
        title=parsed.title,
    )
    apply_feed_metadata(feed, parsed)
    episodes = new_episodes(parsed, known_guids=set())
    if public:
        from audioreader.saved import reconcile

        episodes = await reconcile(session, episodes)
    feed.episodes.extend(episodes)
    session.add(feed)
    await session.commit()
    return feed
