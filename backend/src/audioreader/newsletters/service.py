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
from html import unescape
from pathlib import Path

from sqlalchemy import and_, delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.feeds.fetcher import MAX_ARTICLE_BYTES, FeedFetchError, fetch_public_bytes, post_public
from audioreader.feeds.parser import MAX_CONTENT_CHARS
from audioreader.feeds.search import matches_name
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_BLOCKED,
    APPROVAL_LEFT,
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
    unsubscribe_of,
)
from audioreader.newsletters.signup import (
    SUBSTACK,
    SUBSTACK_SIGN_IN_SUBJECT,
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
#: A step of signing up — a code to type in, a link to sign in with — that
#: nothing here can take. Kept as raw mail for a while, filed nowhere.
SKIPPED = "skipped"

SIGNUP_SUBMITTED = "submitted"
SIGNUP_UNSUPPORTED = "unsupported"
SIGNUP_FAILED = "failed"

#: Mailchimp's notice after the confirmation link is followed. Not an issue.
_SUBSCRIPTION_NOTICE = re.compile(r"^\s*subscription confirmed\s*$", re.IGNORECASE)
#: Mail that is part of signing up rather than the newsletter itself: a code
#: to type in, a link to sign in with. A signup is not complete on the
#: strength of one of these, and the newsletter is not yet writing.
#: "Sign in to" counts only as the subject's opening: a newsletter's own
#: issue may well be about signing in to something.
_TRANSACTIONAL = re.compile(
    r"verification code|verify your email|confirm your (?:email|address|subscription)"
    r"|^\s*(?:please )?(?:sign|log)[- ]in to(?: |$)|(?:sign|log)[- ]in link|login link|magic link|one[- ]time code",
    re.IGNORECASE,
)


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
        # Substack delivers nothing to an address it has not verified, and
        # verifies it through a sign-in email: asked for on her first
        # Substack, then never again.
        first_substack = plan.platform == SUBSTACK and not await _substack_verified(session, user)
        sign_in_requested = await submit_signup(plan, address, request_sign_in=first_substack)
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
    logger.info(
        "signed user %s up to %s via %s%s",
        user.id,
        plan.publication,
        plan.platform,
        " (sign-in email requested)" if sign_in_requested else "",
    )
    return SignupOutcome(
        SIGNUP_SUBMITTED,
        f"I have asked {plan.publication} to send its newsletter to your address. "
        "It will appear in Following when its first email arrives.",
        publication=plan.publication,
        platform=plan.platform,
        address=address,
    )


async def _substack_verified(session: AsyncSession, user: User) -> bool:
    """Has a Substack sign-in email of hers been followed before?

    Once one has, her address is verified with Substack for good, and a
    plain signup is enough for every Substack after it.
    """
    verified = await session.scalar(
        select(NewsletterSignup.id).where(
            NewsletterSignup.user_id == user.id,
            NewsletterSignup.platform == SUBSTACK,
            or_(NewsletterSignup.confirmed_at.is_not(None), NewsletterSignup.completed_at.is_not(None)),
        )
    )
    return verified is not None


async def forget_open_signup(session: AsyncSession, user: User, url: str) -> str | None:
    """Drop an unanswered signup for a site, so it can be asked again.

    For the operator's use when a submission is known not to have gone
    through: the record would otherwise make a second attempt say "already
    asked" for a week. Returns the publication's name, or None if there was
    nothing open.
    """
    try:
        site = normalised_site(url)
    except SignupUnsupported:
        return None
    open_signup = await session.scalar(
        select(NewsletterSignup).where(
            NewsletterSignup.user_id == user.id,
            NewsletterSignup.site_url == site,
            NewsletterSignup.completed_at.is_(None),
        )
    )
    if open_signup is None:
        return None
    publication = open_signup.publication
    await session.delete(open_signup)
    await session.commit()
    return publication


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
    if SUBSTACK_SIGN_IN_SUBJECT.search(message.subject) and domain.endswith("substack.com"):
        # Substack's sign-in email comes from whichever publication it
        # likes, so its sender says nothing. Its subject does: it answers
        # her newest Substack signup still waiting to be verified.
        for signup in sorted(open_signups, key=lambda item: item.id, reverse=True):
            if signup.platform == SUBSTACK and signup.confirmed_at is None and _within_signup_window(signup):
                return signup
        return None
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

    # Gmail asking whether her address will take a forwarding rule's mail.
    # Whoever set the rule up already knows the address, and the worst a yes
    # can do is put a sender in her waiting list; so yes, and not an issue.
    if message.sender.address == GMAIL_FORWARDING_SENDER and (link := forwarding_confirmation_link(message)):
        if await _confirm_gmail_forwarding(link):
            record.error = "forwarding confirmation followed; not an issue"
            session.add(record)
            await session.commit()
            logger.info("confirmed a forwarding rule to user %s's address", user.id)
            return Delivery(CONFIRMED)
        # Left for her, code in the subject, as it would be in any inbox.

    # Mail answering a signup the app made for her: the confirmation link is
    # followed, and whatever comes after it is already approved — she said
    # yes when she asked.
    signup = await _signup_awaiting(session, user, message)
    if signup is not None and signup.confirmed_at is None:
        link = confirmation_link(message.html, message.text, sign_in=bool(_TRANSACTIONAL.search(message.subject)))
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
    if _TRANSACTIONAL.search(message.subject):
        # Substack answers a new address with a code to type in, from an
        # address of its choosing. Nothing here can type it, and a code is
        # not an issue of anything: it is kept as raw mail for a while and
        # filed nowhere, so it never sits at the top of a newsletter.
        logger.info("a signup step needs a person: %r", message.subject[:80])
        record.error = "a sign-up step; not an issue"
        session.add(record)
        await session.commit()
        return Delivery(SKIPPED)

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
    elif feed.approval == APPROVAL_LEFT:
        # She stopped following it and it is still writing: the sender was
        # not told, or did not listen. A fresh question, with what it sent
        # before still there behind it.
        feed.approval = APPROVAL_PENDING
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
    if message.unsubscribe_url:
        # The newest message's, always: the address usually carries a
        # per-subscriber token, and an old one may have expired.
        feed.unsubscribe_url = message.unsubscribe_url
        feed.unsubscribe_post = message.unsubscribe_post
    # The newest message decides this too: a rule set up later makes the
    # newsletter forwarded, and a subscription moved here makes it hers.
    feed.forwarded = message.forwarded or _addressed_elsewhere(message)
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
    # Its feed on the web, for the archive and the artwork. Best effort: the
    # sites involved are other people's, and following her is what matters.
    from audioreader.newsletters.companions import attach_companion

    try:
        await attach_companion(session, feed)
    except Exception:  # noqa: BLE001
        logger.exception("could not look for a feed on the web for newsletter %s", feed_id)
        # The rollback expired everything loaded; the caller still reads the
        # feed, and following her was committed before the search began.
        await session.rollback()
        await session.refresh(feed)
    return feed


async def block(session: AsyncSession, user: User, feed_id: int) -> bool:
    """Refuse a sender for good. Its messages go now, and later ones are
    dropped on arrival. The feed row itself stays as the record of the no."""
    feed = await owned_email_feed(session, user, feed_id)
    if feed is None:
        return False
    # No means no to the sender as well, while its mail is still here to
    # say how.
    await tell_sender_to_stop(session, feed)
    await _delete_contents(session, feed)
    feed.approval = APPROVAL_BLOCKED
    await session.commit()
    return True


async def leave(session: AsyncSession, feed: Feed) -> bool:
    """Stop following a newsletter.

    The sender is asked to stop, the way a mail client's Unsubscribe button
    asks. What it sent is kept for `newsletter_pending_retention_days`, so
    coming back within that time loses nothing, and so a sender that keeps
    writing anyway comes back as a question rather than as silence.
    Returns whether the sender was told.
    """
    told = await tell_sender_to_stop(session, feed)
    await session.execute(delete(Subscription).where(Subscription.feed_id == feed.id))
    feed.approval = APPROVAL_LEFT
    # The quiet clock the prune reads starts now, not at its last issue.
    feed.last_polled_at = utcnow()
    await session.commit()
    return told


async def tell_sender_to_stop(session: AsyncSession, feed: Feed) -> bool:
    """Ask the sender to stop, with its own List-Unsubscribe address.

    A one-click sender (RFC 8058) takes a POST saying `List-Unsubscribe=
    One-Click` and needs no page. Any other web address is opened as she
    would open it from an email: most senders stop on the visit, some show
    a page with a button nothing here can press. Best effort either way —
    the sender's site is somebody else's, and leaving is what matters.
    The outcome is dated on the feed, so a sender that did not accept can
    be asked again.
    """
    feed.stop_tried_at = utcnow()
    if feed.forwarded:
        # The unsubscribe address in forwarded mail is the other inbox's
        # subscription — a paid one, likely. Not ours to end.
        logger.info("%s is forwarded from her own inbox; not telling the sender", feed.title)
        return False
    if not feed.unsubscribe_url:
        await _recover_unsubscribe(session, feed)
    if not feed.unsubscribe_url:
        logger.info("no way to tell %s to stop: its mail gave no unsubscribe address", feed.title)
        return False
    try:
        if feed.unsubscribe_post:
            reply = await post_public(feed.unsubscribe_url, data={"List-Unsubscribe": "One-Click"})
            told = 200 <= reply.status_code < 300
        else:
            await fetch_public_bytes(feed.unsubscribe_url, max_bytes=MAX_ARTICLE_BYTES)
            told = True
    except FeedFetchError as exc:
        logger.warning("could not tell %s to stop at %s: %s", feed.title, site_domain(feed.unsubscribe_url), exc)
        return False
    if told:
        feed.stop_told_at = utcnow()
    logger.info("told %s to stop (%s): %s", feed.title, "one-click" if feed.unsubscribe_post else "link", told)
    return told


def _addressed_elsewhere(message: NewsletterMessage) -> bool:
    """Named for an inbox other than one of ours, so forwarded from it.

    Only when the message names anyone: a newsletter sent to undisclosed
    recipients names nobody, and says nothing either way.
    """
    domain = (settings.inbound_email_domain or "").lower()
    if not domain or not message.addressed_to:
        return False
    return not any(address.endswith("@" + domain) for address in message.addressed_to)


#: Gmail's forwarding verification: sent to the address a rule would forward
#: to, with a link that says yes.
GMAIL_FORWARDING_SENDER = "forwarding-noreply@google.com"
_GMAIL_FORWARDING_LINK = re.compile(r"https://mail-settings\.google\.com/mail/[^\s\"'<>]+")


def forwarding_confirmation_link(message: NewsletterMessage) -> str | None:
    for body in (message.text, message.html):
        if body and (match := _GMAIL_FORWARDING_LINK.search(unescape(body))):
            return match.group(0)
    return None


_CONFIRM_FORM = re.compile(r"<form[^>]*method=[\"']?post", re.IGNORECASE)


async def _confirm_gmail_forwarding(link: str) -> bool:
    """Say yes to Google.

    The link opens a page — "Please confirm mail forwarding of X to Y" —
    whose one button is a form with nothing in it, posted to the page's
    own address. Opening the link alone confirms nothing; pressing the
    button does. Anything else on the page means the request is not
    the one expected, and the message is left for her instead.
    """
    try:
        page, page_url = await fetch_public_bytes(link, max_bytes=MAX_ARTICLE_BYTES)
        if not _CONFIRM_FORM.search(page.decode("utf-8", errors="replace")):
            logger.warning("Google's forwarding page at %s had no Confirm button", site_domain(page_url))
            return False
        reply = await post_public(page_url, data={})
    except FeedFetchError as exc:
        logger.warning("could not confirm a forwarding rule at %s: %s", site_domain(link), exc)
        return False
    return 200 <= reply.status_code < 400


async def _recover_unsubscribe(session: AsyncSession, feed: Feed) -> None:
    """Take the unsubscribe address from the newest raw mail still kept.

    For a newsletter that arrived before addresses were noted on the feed,
    or whose issues never carried one until now.
    """
    raws = await session.scalars(
        select(InboundMessage.raw)
        .where(InboundMessage.feed_id == feed.id, InboundMessage.raw.is_not(None))
        .order_by(InboundMessage.received_at.desc(), InboundMessage.id.desc())
        .limit(10)
    )
    for raw in raws:
        try:
            headers = BytesHeaderParser(policy=email.policy.default).parsebytes(raw or b"")
        except Exception:  # noqa: BLE001 - the email package raises a long tail of its own types
            continue
        url, post = unsubscribe_of(headers)
        if url:
            feed.unsubscribe_url, feed.unsubscribe_post = url, post
            return


async def tell_left_senders(session: AsyncSession, now: datetime | None = None) -> int:
    """Ask again, for senders she left or blocked that have not yet accepted.

    Once a day, and only while there is an address to ask at: a sender
    whose mail never gave one is tried once and then left alone until a
    later message brings one.
    """
    now = now or utcnow()
    due = (
        await session.scalars(
            select(Feed).where(
                Feed.source == FEED_SOURCE_EMAIL,
                Feed.approval.in_((APPROVAL_LEFT, APPROVAL_BLOCKED)),
                Feed.forwarded.is_(False),
                Feed.stop_told_at.is_(None),
                or_(
                    Feed.stop_tried_at.is_(None),
                    and_(Feed.unsubscribe_url.is_not(None), Feed.stop_tried_at < now - timedelta(days=1)),
                ),
            )
        )
    ).all()
    told = 0
    for feed in due:
        told += await tell_sender_to_stop(session, feed)
        await session.commit()
    return told


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
                # Unanswered, or left and not come back to, for long enough.
                Feed.approval.in_((APPROVAL_PENDING, APPROVAL_LEFT)),
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
