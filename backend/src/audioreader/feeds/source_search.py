"""Typed search for something to follow, across every place a feed is listed.

Three sources answer it. Apple's directory knows podcasts, Substack's knows
most newsletters, and our own catalogue knows the written feeds other
listeners already follow, whichever platform they live on. The same feed is
often listed by more than one of them under different addresses (Apple and
the catalogue by HTTP and HTTPS, Substack and the catalogue by a custom
domain and a substack.com subdomain), so results are merged by identity
before anyone sees them: one row per feed, never one per source.
"""

import asyncio
import logging
from urllib.parse import urlsplit, urlunsplit

from sqlalchemy import exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds.poller import feed_is_failing
from audioreader.feeds.private import personalised
from audioreader.feeds.search import (
    PodcastMatch,
    PodcastSearchError,
    feed_key,
    meaningful_words,
    publication_name,
    rank_key,
    search_podcasts,
    search_substack,
)
from audioreader.models import FEED_SOURCE_RSS, Episode, Feed, FeedAlias, Subscription

logger = logging.getLogger(__name__)

_CATALOGUE_LIMIT = 10


async def search_sources(
    session: AsyncSession,
    query: str,
    *,
    country: str | None = None,
    limit: int = 25,
) -> list[PodcastMatch]:
    """Podcasts and publications for a typed query, one row per feed.

    Each directory is best-effort: Substack being down must not hide Apple's
    answer, nor the reverse. A failure is reported only when nothing was
    found, since "no matches" would then be a guess rather than an answer.
    """

    query = query.strip()
    if not query:
        return []
    apple, substack = await asyncio.gather(
        search_podcasts(query, limit=limit, strict=False, country=country),
        search_substack(publication_name(query)),
        return_exceptions=True,
    )
    catalogue = await catalogue_publications(session, query)
    failures = [result for result in (apple, substack) if isinstance(result, BaseException)]
    for failure in failures:
        if not isinstance(failure, PodcastSearchError):
            raise failure
        logger.info("source search for %r: %s", query, failure)
    apple = [] if isinstance(apple, BaseException) else apple
    substack = [] if isinstance(substack, BaseException) else substack

    # Apple first so a podcast keeps its directory details; Substack before
    # the catalogue so a newsletter keeps its writer's name and logo.
    merged = await _merge(session, [*apple, *substack, *catalogue])
    if failures and not merged:
        raise failures[0]
    ranked = sorted(enumerate(merged), key=lambda pair: rank_key(pair[1], query, pair[0]))
    return [match for _, match in ranked][:limit]


async def catalogue_publications(session: AsyncSession, query: str) -> list[PodcastMatch]:
    """Written feeds already in the catalogue whose title has every word.

    Written only: Apple already lists public podcasts, and an audio feed in
    the catalogue that Apple does not list is too often someone's paid feed.
    Possession of a URL is not permission to publish it, so anything that
    looks personalised stays out, as do account-owned and email feeds.
    """

    words = meaningful_words(query)
    if not words:
        return []
    title = func.lower(Feed.title)
    has_audio = exists().where(Episode.feed_id == Feed.id, Episode.audio_url.is_not(None))
    has_items = exists().where(Episode.feed_id == Feed.id)
    followers = (
        select(func.count(Subscription.id)).where(Subscription.feed_id == Feed.id).correlate(Feed).scalar_subquery()
    )
    statement = select(Feed).where(
        Feed.owner_user_id.is_(None),
        Feed.source == FEED_SOURCE_RSS,
        has_items,
        ~has_audio,
        followers > 0,
    )
    for word in words:
        statement = statement.where(
            or_(title.startswith(word, autoescape=True), title.contains(f" {word}", autoescape=True))
        )
    feeds = await session.scalars(statement.order_by(followers.desc(), Feed.id).limit(_CATALOGUE_LIMIT * 2))
    return [
        PodcastMatch(
            title=feed.title,
            feed_url=feed.url,
            artwork_url=feed.image_url or feed.site_image_url,
            kind="publication",
        )
        for feed in feeds
        if not personalised(feed.url) and not feed_is_failing(feed)
    ][:_CATALOGUE_LIMIT]


async def _merge(session: AsyncSession, matches: list[PodcastMatch]) -> list[PodcastMatch]:
    """Collapse rows that are the same feed, keeping the first one's place.

    Two rows are the same feed when they share an address, after HTTP and
    HTTPS are treated alike, or when their addresses are known to the
    catalogue as the same feed (its URL or one of its recorded aliases).
    Later rows only fill in what the first was missing.
    """

    known = await _catalogue_identities(session, [url for match in matches for url in _addresses(match)])
    merged: list[PodcastMatch] = []
    owner: dict[str, int] = {}
    for match in matches:
        keys = {feed_key(url) for url in _addresses(match)}
        keys |= {f"feed:{known[key]}" for key in list(keys) if key in known}
        index = next((owner[key] for key in keys if key in owner), None)
        if index is None:
            index = len(merged)
            merged.append(match)
        else:
            merged[index] = _fill(merged[index], match)
        for key in keys:
            owner.setdefault(key, index)
    return merged


async def _catalogue_identities(session: AsyncSession, urls: list[str]) -> dict[str, int]:
    """Map each address's feed key to the catalogue feed it names, if any."""

    spellings = {spelling for url in urls for spelling in _spellings(url)}
    if not spellings:
        return {}
    rows = list(
        await session.execute(select(Feed.url, Feed.id).where(Feed.url.in_(spellings), Feed.owner_user_id.is_(None)))
    )
    rows += list(
        await session.execute(
            select(FeedAlias.url, FeedAlias.feed_id)
            .join(Feed, Feed.id == FeedAlias.feed_id)
            .where(FeedAlias.url.in_(spellings), Feed.owner_user_id.is_(None))
        )
    )
    return {feed_key(url): feed_id for url, feed_id in rows}


def _addresses(match: PodcastMatch) -> list[str]:
    return [match.feed_url, *match.aliases]


def _spellings(url: str) -> list[str]:
    parts = urlsplit(url)
    return [urlunsplit((scheme, *parts[1:])) for scheme in ("https", "http")]


def _fill(kept: PodcastMatch, other: PodcastMatch) -> PodcastMatch:
    updates = {
        field: getattr(other, field)
        for field in ("publisher", "episode_count", "artwork_url", "itunes_id", "country", "primary_genre")
        if getattr(kept, field) is None and getattr(other, field) is not None
    }
    updates["aliases"] = (*kept.aliases, *(url for url in _addresses(other) if url not in _addresses(kept)))
    return kept.model_copy(update=updates)
