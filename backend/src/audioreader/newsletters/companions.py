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
from datetime import datetime, timedelta

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.parser import FeedParseError
from audioreader.feeds.search import matches_name
from audioreader.models import (
    APPROVAL_BLOCKED,
    FEED_SOURCE_EMAIL,
    FEED_SOURCE_RSS,
    Episode,
    Feed,
    NewsletterSignup,
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
        adopt(feed, companion)
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


async def refresh_dependents(session: AsyncSession, companion: Feed) -> None:
    """After a companion is polled, its newsletters take its latest metadata."""
    dependents = (await session.scalars(select(Feed).where(Feed.companion_feed_id == companion.id))).all()
    for feed in dependents:
        adopt(feed, companion)


def _title_key(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", title.casefold())


def without_duplicates(episodes: list[Episode], own_feed_id: int) -> list[Episode]:
    """The newsletter's items plus the companion's, one row per post.

    An emailed issue and the feed's copy of it are the same post. Hers is
    kept — it is the one she is subscribed to — and the feed's copy is
    dropped when it shares a link or a title. Titles rather than links
    alone, because an email's link is often a tracking redirect.
    """
    own_links = {episode.link for episode in episodes if episode.feed_id == own_feed_id and episode.link}
    own_titles = {_title_key(episode.title) for episode in episodes if episode.feed_id == own_feed_id}
    kept = []
    for episode in episodes:
        if episode.feed_id != own_feed_id:
            if episode.link in own_links or _title_key(episode.title) in own_titles:
                continue
        kept.append(episode)
    return kept
