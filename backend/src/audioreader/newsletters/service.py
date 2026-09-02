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
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from email.parser import BytesHeaderParser
from hashlib import sha256
from pathlib import Path

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds.fetcher import MAX_ARTICLE_BYTES, FeedFetchError, fetch_public_bytes
from audioreader.feeds.parser import MAX_CONTENT_CHARS
from audioreader.feeds.search import matches_name
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_BLOCKED,
    APPROVAL_PENDING,
    FEED_SOURCE_EMAIL,
    Episode,
    Feed,
    InboundMessage,
    NewsletterSignup,
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
from audioreader.newsletters.signup import (
    SignupFailed,
    SignupUnsupported,
    confirmation_link,
    normalised_site,
    plan_signup,
    site_domain,
    submit_signup,
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
#: A confirmation email for a signup the app made: its link was followed and
#: the message itself is not an issue.
CONFIRMED = "confirmed"

SIGNUP_SUBMITTED = "submitted"
SIGNUP_UNSUPPORTED = "unsupported"
SIGNUP_FAILED = "failed"

#: Mailchimp's notice after the confirmation link is followed. Not an issue.
_SUBSCRIPTION_NOTICE = re.compile(r"^\s*subscription confirmed\s*$", re.IGNORECASE)


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


def spoken_address(address: str) -> str:
    """An email address as a voice can say it and a listener can write it down.

    The same shape the app uses on screen: a word address is said word by
    word with the hyphens mentioned once; an older letter address is spelled.
    """
    local, _, domain = address.partition("@")
    domain_words = domain.replace(".", " dot ")
    words = local.split("-")
    if len(words) > 1 and all(word.isalpha() for word in words):
        return f"{', '.join(words)}, with hyphens between the words, at {domain_words}"
    return f"{', '.join(local)}, at {domain_words}"


# --- Signing up on her behalf ------------------------------------------------


@dataclass(frozen=True)
class SignupOutcome:
    status: str
    spoken_response: str
    publication: str | None = None
    platform: str | None = None
    address: str | None = None
    #: For "unsupported": account_required, captcha or no_form.
    reason: str | None = None


async def sign_up(session: AsyncSession, user: User, url: str) -> SignupOutcome:
    """Submit her address to a newsletter's signup, the way its button would.

    Every outcome comes back as a sentence she can act on. When the site
    cannot be signed up to automatically — it wants an account, or a
    CAPTCHA — the sentence carries her address, since the next step is a
    person entering it.
    """
    if not settings.inbound_email_enabled:
        raise NewslettersDisabledError
    address = await inbound_address(session, user)
    manual = (
        f"Your newsletter address is {spoken_address(address)}. "
        "It is also in Settings, where it can be copied or shared."
    )
    try:
        site = normalised_site(url)
    except SignupUnsupported as exc:
        return SignupOutcome(
            SIGNUP_UNSUPPORTED, f"I did not catch a web address. {manual}", address=address, reason=exc.reason
        )
    domain = site_domain(site)

    existing = await session.scalar(
        select(NewsletterSignup).where(
            NewsletterSignup.user_id == user.id,
            NewsletterSignup.site_url == site,
            NewsletterSignup.completed_at.is_(None),
        )
    )
    if existing is not None and _within_signup_window(existing):
        return SignupOutcome(
            SIGNUP_SUBMITTED,
            f"I have already asked {existing.publication} for its newsletter. It will appear in Following when "
            "its first email arrives.",
            publication=existing.publication,
            platform=existing.platform,
            address=address,
        )

    try:
        plan = await plan_signup(site)
    except SignupUnsupported as exc:
        return SignupOutcome(
            SIGNUP_UNSUPPORTED, _unsupported_sentence(exc, domain, manual), address=address, reason=exc.reason
        )
    except FeedFetchError as exc:
        logger.info("could not fetch %s for signup: %s", site, exc)
        return SignupOutcome(SIGNUP_FAILED, f"I could not reach {domain}. {manual}", address=address)

    try:
        await submit_signup(plan, address)
    except SignupUnsupported as exc:
        return SignupOutcome(
            SIGNUP_UNSUPPORTED,
            _unsupported_sentence(exc, domain, manual),
            publication=plan.publication,
            platform=plan.platform,
            address=address,
            reason=exc.reason,
        )
    except SignupFailed as exc:
        logger.info("signup to %s failed: %s", plan.submit_url, exc)
        return SignupOutcome(
            SIGNUP_FAILED,
            f"{plan.publication} did not accept the signup. {manual}",
            publication=plan.publication,
            platform=plan.platform,
            address=address,
        )

    session.add(
        NewsletterSignup(
            user_id=user.id,
            site_url=site,
            publication=plan.publication,
            platform=plan.platform,
            expected_senders=",".join(plan.expected_senders),
        )
    )
    await session.commit()
    logger.info("signed user %s up to %s via %s", user.id, plan.publication, plan.platform)
    return SignupOutcome(
        SIGNUP_SUBMITTED,
        f"I have asked {plan.publication} to send its newsletter to your address. "
        "It will appear in Following when its first email arrives.",
        publication=plan.publication,
        platform=plan.platform,
        address=address,
    )


def _unsupported_sentence(exc: SignupUnsupported, domain: str, manual: str) -> str:
    if exc.reason == "account_required":
        return (
            f"{domain} needs an account before it will send its newsletter, "
            f"so this one has to be signed up by hand. {manual}"
        )
    if exc.reason == "captcha":
        return f"{domain} asks people to prove they are human before signing up, which I cannot do for you. {manual}"
    return f"I could not find a signup form on {domain}. {manual}"


def _as_aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _within_signup_window(signup: NewsletterSignup, now: datetime | None = None) -> bool:
    now = now or utcnow()
    return now - _as_aware(signup.created_at) <= timedelta(days=settings.newsletter_signup_window_days)


async def _signup_awaiting(session: AsyncSession, user: User, message: NewsletterMessage) -> NewsletterSignup | None:
    """The signup this message answers, if the app made one recently.

    Matched on the sender's domain against what the signup expected, or on
    the publication's name against the sender's, and only inside the window:
    a newsletter that first writes months later is a stranger again.
    """
    open_signups = (
        await session.scalars(
            select(NewsletterSignup).where(
                NewsletterSignup.user_id == user.id, NewsletterSignup.completed_at.is_(None)
            )
        )
    ).all()
    sender = message.sender
    domain = sender.address.partition("@")[2]
    for signup in open_signups:
        if not _within_signup_window(signup):
            continue
        expected = [item.strip().lower() for item in signup.expected_senders.split(",") if item.strip()]
        if any(sender.address == item or domain == item or domain.endswith("." + item) for item in expected):
            return signup
        if matches_name(signup.publication, sender.name) or matches_name(sender.name, signup.publication):
            return signup
    return None


async def _follow_confirmation(link: str) -> bool:
    try:
        await fetch_public_bytes(link, max_bytes=MAX_ARTICLE_BYTES)
    except FeedFetchError as exc:
        logger.warning("could not follow a confirmation link at %s: %s", site_domain(link), exc)
        return False
    return True


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

    # Mail answering a signup the app made for her: the confirmation link is
    # followed, and whatever comes after it is already approved — she said
    # yes when she asked.
    signup = await _signup_awaiting(session, user, message)
    if signup is not None and signup.confirmed_at is None:
        link = confirmation_link(message.html, message.text)
        if link and await _follow_confirmation(link):
            signup.confirmed_at = utcnow()
            record.error = "confirmation link followed; not an issue"
            session.add(record)
            await session.commit()
            logger.info("confirmed the %s signup for user %s", signup.publication, user.id)
            return Delivery(CONFIRMED)
    if signup is not None and _SUBSCRIPTION_NOTICE.match(message.subject):
        record.error = "subscription notice; not an issue"
        session.add(record)
        await session.commit()
        return Delivery(CONFIRMED)

    feed = await session.scalar(
        select(Feed).where(Feed.owner_user_id == user.id, Feed.url == feed_url_for(user, message.sender.key))
    )
    if feed is None:
        feed = Feed(
            url=feed_url_for(user, message.sender.key),
            title=message.sender.name,
            source=FEED_SOURCE_EMAIL,
            owner_user_id=user.id,
            approval=APPROVAL_APPROVED if signup is not None else APPROVAL_PENDING,
            description=message.sender.address,
        )
        session.add(feed)
        await session.flush()
    elif feed.approval == APPROVAL_BLOCKED:
        # Her answer was no. Not stored, not even the raw bytes.
        return Delivery(BLOCKED, feed_id=feed.id)
    if signup is not None:
        feed.approval = APPROVAL_APPROVED
        subscribed = await session.scalar(
            select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed.id)
        )
        if subscribed is None:
            session.add(Subscription(user_id=user.id, feed_id=feed.id, latest_after_episode_id=None))
        signup.feed_id = feed.id
        signup.completed_at = utcnow()

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
    await session.execute(delete(NewsletterSignup).where(NewsletterSignup.user_id == user.id))
    await session.execute(delete(Episode).where(Episode.feed_id.in_(owned)))
    await session.execute(delete(Subscription).where(Subscription.feed_id.in_(owned)))
    await session.execute(delete(Feed).where(Feed.owner_user_id == user.id))


@dataclass
class PruneSummary:
    raw_messages: int = 0
    pending_feeds: int = 0
    stale_signups: int = 0


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

    # A signup nothing ever answered, or one long since completed, is only a
    # record now; the feed it made carries on without it.
    signups = await session.execute(delete(NewsletterSignup).where(NewsletterSignup.created_at < pending_cutoff))
    summary.stale_signups = getattr(signups, "rowcount", 0) or 0
    await session.commit()
    if summary.raw_messages or summary.pending_feeds:
        logger.info(
            "newsletter prune: %d raw emails, %d unanswered senders", summary.raw_messages, summary.pending_feeds
        )
    return summary
