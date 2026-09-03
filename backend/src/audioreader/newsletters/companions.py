"""A newsletter's feed on the web, beside the one that arrives by email.

Most newsletters have both: the email she signed up for, and a public RSS
feed with the same posts, the archive, the artwork and the site link. The
email feed is hers alone and stays that way; the RSS feed is shared, as
every fetched feed is. Linking the two gives her newsletter the archive and
the artwork it would have had by subscribing to the feed, without a private
issue ever leaking into the shared catalog.

Where the feed is looked for, in order of trust: the site the app signed
her up on; for a Substack sender, the publication's own substack.com
address; and the sender's domain, taken only when the feed found there is
named like the newsletter — Benedict Evans's essays are not his newsletter.
"""

import logging
import re
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import matches_name
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_BLOCKED,
    FEED_SOURCE_EMAIL,
    FEED_SOURCE_RSS,
    Episode,
    Feed,
    NewsletterSignup,
    Subscription,
    utcnow,
)

logger = logging.getLogger(__name__)

_SUBSTACK_SENDER = re.compile(r"^([a-z0-9-]+)@substack\.com$")
_SUBSTACK_LIST = re.compile(r"^([a-z0-9-]+)\.substack\.com$")
_ADDRESS = re.compile(r"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}", re.IGNORECASE)
_HOSTNAME = re.compile(r"^(?:[a-z0-9-]+\.)+[a-z]{2,}$")
#: List-ID hosts that name a mailing platform's list, not a website:
#: `abc123.list-id.mcsv.net` is Mailchimp's, and there is no site there.
_LIST_ONLY_HOSTS = ("list-id.", "mcsv.net", "lists.")
#: Domains that send on behalf of many publications, and so say nothing
#: about which site is the newsletter's.
_SHARED_MAIL_DOMAINS = (
    "substack.com",
    "beehiiv.com",
    "mail.beehiiv.com",
    "buttondown.email",
    "mailchimpapp.net",
    "list-manage.com",
    "gmail.com",
    "outlook.com",
    "hotmail.com",
    "yahoo.com",
    "icloud.com",
)


def sender_key(feed: Feed) -> str:
    """What tells the newsletter apart, kept in the feed's private URL.

    The List-ID's identifier when the sender sets one — Substack's is the
    publication's `<name>.substack.com` — otherwise the From address with
    the display name's slug after it.
    """
    return feed.url.partition("://")[2].partition("/")[2]


def sender_address(feed: Feed) -> str | None:
    """The address the newsletter writes from, when the key is one."""
    match = _ADDRESS.search(sender_key(feed))
    return match.group(0).lower() if match else None


def list_host(feed: Feed) -> str | None:
    """The List-ID identifier, when it is a hostname."""
    key = sender_key(feed).partition("/")[0].lower()
    return key if _HOSTNAME.match(key) and "@" not in key else None


def _shared(domain: str) -> bool:
    return any(domain == shared or domain.endswith("." + shared) for shared in _SHARED_MAIL_DOMAINS)


def candidate_sites(feed: Feed, signup_site: str | None = None) -> list[tuple[str, bool]]:
    """Where the newsletter's feed might be, as (site, must_match_name)."""
    candidates: list[tuple[str, bool]] = []
    if signup_site:
        candidates.append((signup_site, False))
    address = sender_address(feed)
    host = list_host(feed)
    if address:
        if match := _SUBSTACK_SENDER.match(address):
            candidates.append((f"https://{match.group(1)}.substack.com", False))
        domain = address.partition("@")[2]
        if domain and not _shared(domain):
            candidates.append((f"https://{domain}", True))
    elif host:
        if _SUBSTACK_LIST.match(host):
            candidates.append((f"https://{host}", False))
        elif not _shared(host) and not any(marker in host for marker in _LIST_ONLY_HOSTS):
            candidates.append((f"https://{host}", True))
    seen: set[str] = set()
    unique = []
    for site, must_match in candidates:
        if site not in seen:
            seen.add(site)
            unique.append((site, must_match))
    return unique


def adopt(feed: Feed, companion: Feed) -> None:
    """Give the email feed the companion's name, face and blurb."""
    if companion.title:
        feed.title = companion.title
    feed.description = companion.description
    feed.image_url = companion.image_url
    feed.site_image_url = companion.site_image_url
    feed.site_url = companion.site_url


async def attach_companion(session: AsyncSession, feed: Feed, *, signup_site: str | None = None) -> Feed | None:
    """Find and link the newsletter's feed on the web, if it has one.

    Every attempt is dated, so a newsletter with no feed is not searched for
    on every pass — only again after `newsletter_companion_retry_days`.
    """
    if feed.source != FEED_SOURCE_EMAIL:
        return None
    candidates = candidate_sites(feed, signup_site)
    if not candidates:
        logger.info("nowhere to look for a companion feed for %s (%s)", feed.title, sender_key(feed))
    for site, must_match in candidates:
        try:
            companion = await feed_service.ensure_feed(session, site)
        except (FeedFetchError, FeedParseError) as exc:
            logger.info("no companion feed for %s at %s: %s", feed.title, site, exc)
            continue
        if companion.id == feed.id or companion.source != FEED_SOURCE_RSS:
            continue
        if must_match and not (matches_name(feed.title, companion.title) or matches_name(companion.title, feed.title)):
            logger.info("feed at %s is %r, not %r; not linked", site, companion.title, feed.title)
            continue
        feed.companion_feed_id = companion.id
        feed.companion_checked_at = utcnow()
        # What the feed already holds is the archive, not news.
        feed.companion_latest_after_episode_id = await session.scalar(
            select(func.max(Episode.id)).where(Episode.feed_id == companion.id)
        )
        adopt(feed, companion)
        await fold_subscription(session, feed)
        await session.commit()
        logger.info("linked newsletter %s to its feed %s", feed.title, companion.url)
        return companion
    feed.companion_checked_at = utcnow()
    await session.commit()
    return None


async def attach_missing_companions(session: AsyncSession, now: datetime | None = None) -> int:
    """Link every newsletter that has no feed yet and is due another look."""
    now = now or utcnow()
    cutoff = now - timedelta(days=settings.newsletter_companion_retry_days)
    due = (
        await session.scalars(
            select(Feed).where(
                Feed.source == FEED_SOURCE_EMAIL,
                Feed.companion_feed_id.is_(None),
                Feed.approval != APPROVAL_BLOCKED,
                or_(Feed.companion_checked_at.is_(None), Feed.companion_checked_at < cutoff),
            )
        )
    ).all()
    linked = 0
    for feed in due:
        signup_site = await session.scalar(
            select(NewsletterSignup.site_url)
            .where(NewsletterSignup.feed_id == feed.id)
            .order_by(NewsletterSignup.id.desc())
            .limit(1)
        )
        try:
            if await attach_companion(session, feed, signup_site=signup_site) is not None:
                linked += 1
        except Exception:  # noqa: BLE001 - one newsletter's trouble must not stop the pass
            logger.exception("could not look for a companion feed for %s", feed.title)
            await session.rollback()
    return linked


async def fold_subscription(session: AsyncSession, feed: Feed) -> bool:
    """One row for one publication.

    A newsletter whose companion she also follows by RSS would show her
    the publication twice, and every post twice — the feed's copy and the
    emailed one, which for a paid post is the only complete one. The RSS
    subscription goes; the newsletter, wearing the publication's name,
    shows the feed's posts as well. Not committed here.
    """
    if feed.companion_feed_id is None or feed.owner_user_id is None or feed.approval != APPROVAL_APPROVED:
        return False
    following = await session.scalar(
        select(Subscription).where(Subscription.user_id == feed.owner_user_id, Subscription.feed_id == feed.id)
    )
    if following is None:
        return False
    result = await session.execute(
        delete(Subscription).where(
            Subscription.user_id == feed.owner_user_id, Subscription.feed_id == feed.companion_feed_id
        )
    )
    folded = bool(getattr(result, "rowcount", 0))
    if folded:
        logger.info("folded an RSS subscription into the newsletter %s", feed.title)
    return folded


async def newsletter_for(session: AsyncSession, user_id: uuid.UUID, feed_id: int) -> Feed | None:
    """The newsletter of hers that already shows this feed, if any."""
    return await session.scalar(
        select(Feed)
        .join(Subscription, Subscription.feed_id == Feed.id)
        .where(
            Subscription.user_id == user_id,
            Feed.owner_user_id == user_id,
            Feed.source == FEED_SOURCE_EMAIL,
            Feed.companion_feed_id == feed_id,
        )
    )


def her_feed_ids(user_id: uuid.UUID):
    """Every feed whose items are hers to hear: the ones she follows, and
    the companions of the newsletters among them. A subquery."""
    followed = select(Subscription.feed_id).where(Subscription.user_id == user_id)
    companions = (
        select(Feed.companion_feed_id)
        .join(Subscription, Subscription.feed_id == Feed.id)
        .where(Subscription.user_id == user_id, Feed.companion_feed_id.is_not(None))
    )
    return followed.union(companions)


def companion_news(user_id: uuid.UUID):
    """A companion's posts since its newsletter was linked, or since Latest
    was last cleared — the part of the feed that is news to her. A select."""
    return (
        select(Episode)
        .join(Feed, Feed.companion_feed_id == Episode.feed_id)
        .join(Subscription, Subscription.feed_id == Feed.id)
        .where(
            Subscription.user_id == user_id,
            or_(
                Feed.companion_latest_after_episode_id.is_(None),
                Episode.id > Feed.companion_latest_after_episode_id,
            ),
        )
    )


async def without_feed_copies(session: AsyncSession, episodes: list[Episode], user_id: uuid.UUID) -> list[Episode]:
    """Drop a companion's copy of any post she was sent by email.

    Across all her newsletters at once: the emailed copy is hers and, for
    a paid post, the whole of it; the feed's is a preview at best.
    """
    pairs = (
        await session.execute(
            select(Feed.id, Feed.companion_feed_id)
            .join(Subscription, Subscription.feed_id == Feed.id)
            .where(Subscription.user_id == user_id, Feed.companion_feed_id.is_not(None))
        )
    ).all()
    if not pairs:
        return episodes
    newsletter_of = {companion_id: feed_id for feed_id, companion_id in pairs}
    emailed = list(
        (
            await session.execute(
                select(Episode.feed_id, Episode.title, Episode.link).where(
                    Episode.feed_id.in_([feed_id for feed_id, _ in pairs])
                )
            )
        ).tuples()
    )
    posts = {feed_id: _Posts(feed_id, [row for row in emailed if row[0] == feed_id]) for feed_id, _ in pairs}
    kept = []
    for episode in episodes:
        newsletter_id = newsletter_of.get(episode.feed_id)
        if newsletter_id is not None and posts[newsletter_id].is_the_feeds_copy(
            episode.feed_id, episode.title, episode.link
        ):
            continue
        kept.append(episode)
    return kept


#: Sorts an undated item last, however new its id is.
_UNDATED = datetime.min.replace(tzinfo=UTC)


def newest_first(episode: Episode) -> tuple[datetime, int]:
    """A sort key for merging lists the database sorted separately.

    SQLite hands back naive datetimes and Postgres aware ones; the key
    makes them comparable rather than trusting either.
    """
    when = episode.published_at or _UNDATED
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return when, episode.id


async def refresh_dependents(session: AsyncSession, companion: Feed) -> None:
    """After a companion is polled, its newsletters take its latest metadata."""
    dependents = (await session.scalars(select(Feed).where(Feed.companion_feed_id == companion.id))).all()
    for feed in dependents:
        adopt(feed, companion)


def _title_key(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", title.casefold())


class _Posts:
    """Her issues' links and titles, for telling the feed's copies apart.

    An emailed issue and the feed's copy of it are the same post. Hers is
    kept — it is the one she is subscribed to — and the feed's copy is
    dropped when it shares a link or a title. Titles rather than links
    alone, because an email's link is often a tracking redirect.
    """

    def __init__(self, own_feed_id: int, rows: list[tuple[int, str, str | None]]) -> None:
        self.own_feed_id = own_feed_id
        self.links = {link for feed_id, _, link in rows if feed_id == own_feed_id and link}
        self.titles = {_title_key(title) for feed_id, title, _ in rows if feed_id == own_feed_id}

    def is_the_feeds_copy(self, feed_id: int, title: str, link: str | None) -> bool:
        return feed_id != self.own_feed_id and (link in self.links or _title_key(title) in self.titles)


def without_duplicates(episodes: list[Episode], own_feed_id: int) -> list[Episode]:
    """The newsletter's items plus the companion's, one row per post."""
    posts = _Posts(own_feed_id, [(episode.feed_id, episode.title, episode.link) for episode in episodes])
    return [
        episode for episode in episodes if not posts.is_the_feeds_copy(episode.feed_id, episode.title, episode.link)
    ]


async def item_counts(session: AsyncSession, feed: Feed) -> tuple[int, int]:
    """How many posts the newsletter's page shows, and how many carry audio.

    Counted the way the page lists them: her issues and the companion's
    archive together, one per post. Cheap enough because a newsletter has
    a handful of issues and a feed a few hundred posts at most.
    """
    rows = (
        await session.execute(
            select(Episode.feed_id, Episode.title, Episode.link, Episode.audio_url).where(
                Episode.feed_id.in_([feed.id, feed.companion_feed_id])
            )
        )
    ).all()
    posts = _Posts(feed.id, [(feed_id, title, link) for feed_id, title, link, _ in rows])
    kept = [row for row in rows if not posts.is_the_feeds_copy(row[0], row[1], row[2])]
    return len(kept), sum(1 for row in kept if row[3] is not None)
