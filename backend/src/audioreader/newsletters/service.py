"""Her inbound address, and what happens to each email that reaches it.

A newsletter becomes an ordinary feed — `source` "email", owned by her, never
polled — and each issue an episode in it, so reading, searching and filing
need nothing new. What is new is consent: the first message from a sender
makes a feed that is *pending*, invisible to Latest and the library until she
says yes. Anyone who learns her address can send her mail; nobody can put
anything in front of her without her approving the sender first.
"""

import email
import email.policy
import hmac
import logging
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from email.parser import BytesHeaderParser
from hashlib import sha256
from pathlib import Path

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds.parser import MAX_CONTENT_CHARS
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_BLOCKED,
    APPROVAL_PENDING,
    FEED_SOURCE_EMAIL,
    Episode,
    Feed,
    InboundMessage,
    PlaybackPosition,
    Subscription,
    User,
    utcnow,
)
from audioreader.newsletters.cleaning import clean_newsletter_html
from audioreader.newsletters.parser import (
    NewsletterMessage,
    NewsletterParseError,
    parse_newsletter,
    recipient_of,
    text_as_html,
)
from audioreader.text import summarise

logger = logging.getLogger(__name__)

#: The address will be said down a phone and typed by somebody else, so it
#: is made of words rather than letters: "quiet-heron-otter". The list is
#: the EFF's short wordlist for dice passphrases, chosen because its words
#: are short, are not homophones of each other, and have unique three-letter
#: prefixes so a typo is still recognisable. Three of them is about 31 bits,
#: which is plenty when the worst a guess can do is put a row in her pending
#: list.
TOKEN_WORDS = 3
_WORDS = tuple(
    line.strip()
    for line in (Path(__file__).with_name("wordlist.txt")).read_text().splitlines()
    if line.strip() and not line.startswith("#")
)

DELIVERED = "delivered"
PENDING = "pending"
BLOCKED = "blocked"
DUPLICATE = "duplicate"
FAILED = "failed"


class NewslettersDisabledError(Exception):
    """No inbound domain or secret is configured on this deployment."""


@dataclass(frozen=True)
class Delivery:
    status: str
    feed_id: int | None = None
    episode_id: int | None = None


@dataclass(frozen=True)
class PendingSender:
    feed: Feed
    message_count: int
    latest_title: str | None
    latest_at: datetime | None


def new_inbound_token() -> str:
    return "-".join(secrets.choice(_WORDS) for _ in range(TOKEN_WORDS))


def address_for(user: User) -> str | None:
    if not user.inbound_token or not settings.inbound_email_domain:
        return None
    return f"{user.inbound_token}@{settings.inbound_email_domain}"


async def inbound_address(session: AsyncSession, user: User) -> str:
    """Her address, minted the first time she asks for it."""
    if not settings.inbound_email_enabled:
        raise NewslettersDisabledError
    if user.inbound_token is None:
        user.inbound_token = new_inbound_token()
        await session.commit()
    address = address_for(user)
    assert address is not None
    return address


async def user_for_recipient(session: AsyncSession, recipient: str | None) -> User | None:
    if not recipient or not settings.inbound_email_domain:
        return None
    local, _, domain = recipient.strip().lower().partition("@")
    if domain != settings.inbound_email_domain.lower():
        return None
    # Subaddressing is tolerated but not relied on: some signup forms refuse
    # a plus sign, so nothing about the design needs one.
    local = local.split("+", 1)[0]
    if not local:
        return None
    return await session.scalar(select(User).where(User.inbound_token == local))


def signature_for(raw: bytes, secret: str | None = None) -> str:
    key = (settings.inbound_email_secret if secret is None else secret).encode()
    return "sha256=" + hmac.new(key, raw, sha256).hexdigest()


def signature_is_valid(raw: bytes, presented: str | None) -> bool:
    if not presented or not settings.inbound_email_secret:
        return False
    return hmac.compare_digest(signature_for(raw), presented.strip())


def recipient_from_headers(raw: bytes) -> str | None:
    """The To address, for when the envelope recipient was not passed along."""
    try:
        message = BytesHeaderParser(policy=email.policy.default).parsebytes(raw)
    except Exception:  # noqa: BLE001 - any failure here just means "unknown"
        return None
    return recipient_of(message)


def feed_url_for(user: User, sender_key: str) -> str:
    """A private identifier in the feed table's URL column. Never fetched."""
    return f"email://{user.id}/{sender_key}"


async def receive(session: AsyncSession, user: User, raw: bytes) -> Delivery:
    """File one email for its recipient.

    The raw bytes are stored before anything else is attempted, so a message
    the parser cannot handle is kept for a fixed rather than lost: the sender
    will not send it again.
    """
    record = InboundMessage(user_id=user.id, message_id="", raw=raw, raw_size=len(raw))
    try:
        message = parse_newsletter(raw)
    except NewsletterParseError as exc:
        record.message_id = "unparsed"
        record.error = str(exc)[:500]
        session.add(record)
        await session.commit()
        logger.warning("could not parse an inbound email for user %s: %s", user.id, exc)
        return Delivery(FAILED)
    record.message_id = message.message_id

    feed = await session.scalar(
        select(Feed).where(Feed.owner_user_id == user.id, Feed.url == feed_url_for(user, message.sender.key))
    )
    if feed is None:
        feed = Feed(
            url=feed_url_for(user, message.sender.key),
            title=message.sender.name,
            source=FEED_SOURCE_EMAIL,
            owner_user_id=user.id,
            approval=APPROVAL_PENDING,
            description=message.sender.address,
        )
        session.add(feed)
        await session.flush()
    elif feed.approval == APPROVAL_BLOCKED:
        # Her answer was no. Not stored, not even the raw bytes.
        return Delivery(BLOCKED, feed_id=feed.id)

    existing_id = await session.scalar(
        select(Episode.id).where(Episode.feed_id == feed.id, Episode.guid == message.message_id)
    )
    if existing_id is not None:
        return Delivery(DUPLICATE, feed_id=feed.id, episode_id=existing_id)

    episode = episode_for(message)
    episode.feed_id = feed.id
    session.add(episode)
    # Doubles as "last message received" for an email feed; the pending prune
    # reads it to tell a sender that has gone quiet from one still writing.
    feed.last_polled_at = utcnow()
    await session.flush()
    record.feed_id = feed.id
    record.episode_id = episode.id
    session.add(record)
    await session.commit()
    status = PENDING if feed.approval == APPROVAL_PENDING else DELIVERED
    return Delivery(status, feed_id=feed.id, episode_id=episode.id)


def episode_for(message: NewsletterMessage) -> Episode:
    """The issue as an article: cleaned markup, a teaser, and the web copy's
    address when the email gives one."""
    browser_url = None
    preview = None
    content = ""
    if message.html:
        cleaned = clean_newsletter_html(message.html, subject=message.subject)
        content = cleaned.html
        browser_url = cleaned.browser_url
        preview = cleaned.preview_text
    if not content and message.text:
        content = text_as_html(message.text)
    if not content and message.html:
        # The cleaner took everything, which means it misjudged something.
        # The uncleaned issue is still readable; a missing one is not.
        content = message.html
    content = content[:MAX_CONTENT_CHARS]
    return Episode(
        guid=message.message_id,
        title=message.subject,
        # The hidden preview line is written as the one-line summary, which
        # is exactly what the list and the spoken search want.
        description=preview or summarise(content) or None,
        content_html=content,
        author=message.sender.name,
        published_at=message.sent_at or utcnow(),
        link=browser_url,
    )


async def owned_email_feed(session: AsyncSession, user: User, feed_id: int) -> Feed | None:
    feed = await session.get(Feed, feed_id)
    if feed is None or feed.source != FEED_SOURCE_EMAIL or feed.owner_user_id != user.id:
        return None
    return feed


async def pending_senders(session: AsyncSession, user: User) -> list[PendingSender]:
    """Senders waiting for her answer, most recently heard from first."""
    counts = (
        select(
            Episode.feed_id,
            func.count(Episode.id).label("message_count"),
            func.max(Episode.published_at).label("latest_at"),
        )
        .group_by(Episode.feed_id)
        .subquery()
    )
    rows = await session.execute(
        select(Feed, func.coalesce(counts.c.message_count, 0), counts.c.latest_at)
        .outerjoin(counts, counts.c.feed_id == Feed.id)
        .where(Feed.owner_user_id == user.id, Feed.approval == APPROVAL_PENDING)
        .order_by(counts.c.latest_at.desc().nulls_last(), Feed.id.desc())
    )
    pending = []
    for feed, message_count, latest_at in rows.all():
        latest_title = await session.scalar(
            select(Episode.title)
            .where(Episode.feed_id == feed.id)
            .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
            .limit(1)
        )
        pending.append(PendingSender(feed, message_count, latest_title, latest_at))
    return pending


async def approve(session: AsyncSession, user: User, feed_id: int) -> Feed | None:
    """Follow a sender. Everything it has already sent lands in Latest: she
    is saying yes to the messages she was asked about, not only to the next
    one. Approving twice is harmless."""
    feed = await owned_email_feed(session, user, feed_id)
    if feed is None or feed.approval == APPROVAL_BLOCKED:
        return None
    feed.approval = APPROVAL_APPROVED
    subscribed = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed.id)
    )
    if subscribed is None:
        session.add(Subscription(user_id=user.id, feed_id=feed.id, latest_after_episode_id=None))
    await session.commit()
    return feed


async def block(session: AsyncSession, user: User, feed_id: int) -> bool:
    """Refuse a sender for good. Its messages go now, and later ones are
    dropped on arrival. The feed row itself stays as the record of the no."""
    feed = await owned_email_feed(session, user, feed_id)
    if feed is None:
        return False
    await _delete_contents(session, feed)
    feed.approval = APPROVAL_BLOCKED
    await session.commit()
    return True


async def delete_feed(session: AsyncSession, feed: Feed) -> None:
    """Remove a private feed and everything in it. Used when she stops
    following a newsletter: nobody else has any use for it, and its next
    issue should arrive as a fresh question rather than into a feed she left."""
    await _delete_contents(session, feed)
    await session.delete(feed)
    await session.commit()


async def _delete_contents(session: AsyncSession, feed: Feed) -> None:
    episode_ids = select(Episode.id).where(Episode.feed_id == feed.id)
    await session.execute(delete(PlaybackPosition).where(PlaybackPosition.episode_id.in_(episode_ids)))
    await session.execute(delete(InboundMessage).where(InboundMessage.feed_id == feed.id))
    await session.execute(delete(Episode).where(Episode.feed_id == feed.id))
    await session.execute(delete(Subscription).where(Subscription.feed_id == feed.id))


async def delete_all_for_user(session: AsyncSession, user: User) -> None:
    """Her newsletters, on the way out of the account. Not committed here:
    the caller is in the middle of erasing everything else too."""
    owned = select(Feed.id).where(Feed.owner_user_id == user.id)
    episode_ids = select(Episode.id).where(Episode.feed_id.in_(owned))
    await session.execute(delete(PlaybackPosition).where(PlaybackPosition.episode_id.in_(episode_ids)))
    await session.execute(delete(InboundMessage).where(InboundMessage.user_id == user.id))
    await session.execute(delete(Episode).where(Episode.feed_id.in_(owned)))
    await session.execute(delete(Subscription).where(Subscription.feed_id.in_(owned)))
    await session.execute(delete(Feed).where(Feed.owner_user_id == user.id))


@dataclass
class PruneSummary:
    raw_messages: int = 0
    pending_feeds: int = 0


async def prune_newsletters(session: AsyncSession, now: datetime | None = None) -> PruneSummary:
    """Let go of what the retention settings say to let go of.

    Raw emails first: they are hers, and were only ever kept for reprocessing.
    Then senders she never answered, once they have been quiet long enough
    that the question has plainly gone stale — the next message from one of
    them asks again.
    """
    now = now or utcnow()
    summary = PruneSummary()

    raw_cutoff = now - timedelta(days=settings.inbound_raw_retention_days)
    result = await session.execute(delete(InboundMessage).where(InboundMessage.received_at < raw_cutoff))
    summary.raw_messages = getattr(result, "rowcount", 0) or 0

    pending_cutoff = now - timedelta(days=settings.newsletter_pending_retention_days)
    stale = (
        await session.scalars(
            select(Feed).where(
                Feed.source == FEED_SOURCE_EMAIL,
                Feed.approval == APPROVAL_PENDING,
                func.coalesce(Feed.last_polled_at, Feed.created_at) < pending_cutoff,
            )
        )
    ).all()
    for feed in stale:
        await _delete_contents(session, feed)
        await session.delete(feed)
    summary.pending_feeds = len(stale)
    await session.commit()
    if summary.raw_messages or summary.pending_feeds:
        logger.info(
            "newsletter prune: %d raw emails, %d unanswered senders", summary.raw_messages, summary.pending_feeds
        )
    return summary
