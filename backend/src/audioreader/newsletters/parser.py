"""One raw email, reduced to the parts an issue of a newsletter is made of.

The standard library's `email` package does the MIME work: it walks the
multipart tree, undoes transfer encodings, applies each part's charset and
decodes encoded-word headers. What is left for this module is choosing which
part is the issue, and working out which newsletter sent it.
"""

import email
import email.policy
import hashlib
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from email.message import EmailMessage, Message
from email.utils import getaddresses, parseaddr, parsedate_to_datetime
from html import escape, unescape

MAX_SUBJECT_CHARS = 1_000

_WHITESPACE = re.compile(r"\s+")
#: `List-ID: Money Stuff <moneystuff.list-id.example.com>` — an optional
#: description followed by the identifier in angle brackets (RFC 2919).
_LIST_ID = re.compile(r"^\s*(?P<description>.*?)\s*<(?P<identifier>[^>]+)>\s*$")
#: Mailchimp's description is the audience's hex id followed by "mc list",
#: which is not a name anybody would recognise their newsletter by.
_OPAQUE_DESCRIPTION = re.compile(r"^[0-9a-f]{16,}", re.IGNORECASE)


class NewsletterParseError(Exception):
    """The bytes were not an email with a sender and a readable body."""


@dataclass(frozen=True)
class Sender:
    """Which newsletter a message came from, and what to call it."""

    #: What tells one newsletter apart from another at the same publisher:
    #: the List-ID when the sender sets one, otherwise the From address and
    #: display name together. Bloomberg sends every one of its newsletters
    #: from a single address and sets no List-ID; only the name differs.
    key: str
    address: str
    name: str


@dataclass(frozen=True)
class NewsletterMessage:
    message_id: str
    subject: str
    sender: Sender
    #: The first To address, lower-cased. The envelope recipient is more
    #: reliable and arrives separately; this is the fallback.
    recipient: str | None
    sent_at: datetime | None
    html: str | None
    text: str | None
    #: How the sender says to stop: the https address in List-Unsubscribe,
    #: and the List-Unsubscribe-Post value when it takes a one-click POST.
    unsubscribe_url: str | None = None
    unsubscribe_post: str | None = None
    #: Came by way of another inbox: a forwarding rule's headers, or a
    #: message she forwarded by hand (then `sender` is the original one).
    forwarded: bool = False
    #: Everyone in To and Cc, lower-cased. A newsletter addressed to an
    #: inbox other than hers was forwarded from it.
    addressed_to: tuple[str, ...] = ()


def parse_newsletter(raw: bytes) -> NewsletterMessage:
    try:
        message = email.message_from_bytes(raw, policy=email.policy.default)
        return _from_message(message, raw)
    except NewsletterParseError:
        raise
    except Exception as exc:  # the email package raises a long tail of its own types
        raise NewsletterParseError(f"could not parse email: {exc}") from exc


def _from_message(message: Message, raw: bytes) -> NewsletterMessage:
    from_name, from_address = parseaddr(_header(message, "From"))
    from_address = from_address.strip().lower()
    if not from_address:
        raise NewsletterParseError("email has no sender")

    html = _body(message, "html")
    text = _body(message, "plain")
    unsubscribe_url, unsubscribe_post = unsubscribe_of(message)
    subject = _subject(message)
    sender = _sender(message, from_name, from_address)
    forwarded = any(_header(message, name).strip() for name in _FORWARDING_HEADERS)
    if original := forwarded_original(subject, html, text):
        # She forwarded it herself: the mail is from her, the issue is not.
        sender = original
        subject = _FORWARDED_SUBJECT.sub("", subject).strip() or subject
        forwarded = True
    if not (html and html.strip()) and not (text and text.strip()):
        raise NewsletterParseError("email has no readable body")

    return NewsletterMessage(
        message_id=_message_id(message, raw),
        subject=subject,
        sender=sender,
        recipient=recipient_of(message),
        sent_at=_sent_at(message),
        html=html if html and html.strip() else None,
        text=text if text and text.strip() else None,
        unsubscribe_url=unsubscribe_url,
        unsubscribe_post=unsubscribe_post,
        forwarded=forwarded,
        addressed_to=addressed_to(message),
    )


#: What a forwarding rule adds: Gmail's automatic forwarding marks the
#: message with X-Forwarded-*, and a resent message (RFC 5322 section
#: 3.6.6, which Apple Mail's Redirect and some rules use) with Resent-*.
_FORWARDING_HEADERS = ("X-Forwarded-For", "X-Forwarded-To", "Resent-From", "Resent-To")
_FORWARDED_SUBJECT = re.compile(r"^\s*(?:(?:fwd?|fw|tr|wg)\s*:\s*)+", re.IGNORECASE)
#: The line a mail app puts above a message forwarded by hand, and the
#: header lines it copies underneath.
_FORWARDED_BLOCK = re.compile(
    r"(?:-{2,}\s*Forwarded message\s*-{2,}|Begin forwarded message:|-{2,}\s*Original Message\s*-{2,})"
    r"(?P<head>.{0,1200})",
    re.IGNORECASE | re.DOTALL,
)
_FORWARDED_FROM = re.compile(r"\bFrom:\s*(?P<from>[^\r\n]+)", re.IGNORECASE)
_BRACKETED_ADDRESS = re.compile(r"<\s*(?P<address>[^<>\s@]+@[^<>\s]+)\s*>")
_BARE_ADDRESS = re.compile(r"(?P<address>[^\s<>@\"]+@[^\s<>\"]+)")
#: Tags that end a line in a mail app's rendering; the rest are inline.
_LINE_BREAK = re.compile(r"<(?:br|/p|/div|/tr|/li|/h[1-6]|/blockquote|/td)\b[^>]*>", re.IGNORECASE)
_TAG = re.compile(r"<[^>]+>")


def forwarded_original(subject: str, html: str | None, text: str | None) -> Sender | None:
    """Who really wrote a message she forwarded by hand.

    Only looked for under a "Fwd:" subject — an issue may quote a forwarded
    message of its own — and taken from the From line the mail app copied
    above the original. There is no List-ID by then; the address and name
    tell the newsletter apart, as they do for any sender without one.
    """
    if not _FORWARDED_SUBJECT.match(subject):
        return None
    if text and text.strip():
        source = text
    else:
        # Line ends first, then the other tags, then entities: the copied
        # "&lt;address&gt;" must come out as brackets, not go as a tag.
        source = unescape(_TAG.sub(" ", _LINE_BREAK.sub("\n", html or "")))
    block = _FORWARDED_BLOCK.search(source)
    if not block:
        return None
    line = _FORWARDED_FROM.search(block.group("head"))
    if not line:
        return None
    written = _WHITESPACE.sub(" ", line.group("from")).strip()
    bracketed = _BRACKETED_ADDRESS.search(written)
    found = bracketed or _BARE_ADDRESS.search(written)
    if not found:
        return None
    address = found.group("address").lower().strip(".,;")
    name = written[: found.start()].strip().strip('"').rstrip(",").strip() if bracketed else ""
    key = f"{address}/{_slug(name)}" if name else address
    return Sender(key=key, address=address, name=(name or address.partition("@")[0])[:200])


def addressed_to(message: Message) -> tuple[str, ...]:
    """Everyone the message names in To and Cc."""
    pairs = getaddresses([_header(message, "To"), _header(message, "Cc")])
    return tuple(address.strip().lower() for _, address in pairs if "@" in address)


#: `List-Unsubscribe: <mailto:...>, <https://...>` — any number of addresses
#: in angle brackets; only a web one is any use here.
_UNSUBSCRIBE_LINK = re.compile(r"<\s*(https?://[^>\s]+)\s*>", re.IGNORECASE)
_ONE_CLICK = re.compile(r"^\s*List-Unsubscribe=One-Click\s*$", re.IGNORECASE)


def unsubscribe_of(message: Message) -> tuple[str | None, str | None]:
    """How the sender says to stop, from its List-Unsubscribe headers.

    The web address, and the List-Unsubscribe-Post value when the sender
    takes RFC 8058's one-click POST — which is what a mail client's
    Unsubscribe button sends, and the only form that needs no page.
    """
    match = _UNSUBSCRIBE_LINK.search(_header(message, "List-Unsubscribe"))
    if not match:
        return None, None
    post = _header(message, "List-Unsubscribe-Post").strip()
    return match.group(1)[:2_000], post if _ONE_CLICK.match(post) else None


def _header(message: Message, name: str) -> str:
    value = message.get(name)
    return "" if value is None else str(value)


def _message_id(message: Message, raw: bytes) -> str:
    value = _header(message, "Message-ID").strip().strip("<>").strip()
    if value:
        return value[:1_000]
    # No Message-ID is rare and non-compliant; the bytes themselves are the
    # only stable identity left, and they are enough to spot a redelivery.
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def _subject(message: Message) -> str:
    subject = _WHITESPACE.sub(" ", _header(message, "Subject")).strip()
    return subject[:MAX_SUBJECT_CHARS] or "Untitled"


def _sender(message: Message, from_name: str, from_address: str) -> Sender:
    list_id = _header(message, "List-ID").strip()
    key = from_address
    if from_name.strip():
        key = f"{from_address}/{_slug(from_name)}"
    description = ""
    if list_id:
        match = _LIST_ID.match(list_id)
        if match:
            key = match.group("identifier").strip().lower() or from_address
            description = match.group("description").strip().strip('"')
        else:
            key = list_id.lower()
    if _OPAQUE_DESCRIPTION.match(description):
        description = ""
    name = description or from_name.strip() or from_address.partition("@")[0]
    return Sender(key=key, address=from_address, name=_WHITESPACE.sub(" ", name)[:200])


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:80]


def recipient_of(message: Message) -> str | None:
    """The address this was delivered to, from the headers alone."""
    for header in ("Delivered-To", "X-Original-To", "To"):
        _, address = parseaddr(_header(message, header))
        if address:
            return address.strip().lower()
    return None


def _sent_at(message: Message) -> datetime | None:
    value = _header(message, "Date").strip()
    if not value:
        return None
    try:
        sent = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if sent.tzinfo is None:
        sent = sent.replace(tzinfo=UTC)
    return sent


def _body(message: Message, subtype: str) -> str | None:
    if not isinstance(message, EmailMessage):
        return None
    part = message.get_body(preferencelist=(subtype,))
    if part is None:
        return None
    try:
        content = part.get_content()
    except (LookupError, UnicodeDecodeError, KeyError):
        # An unknown or mislabelled charset. The bytes are still there; read
        # them leniently rather than lose the whole issue over one accent.
        payload = part.get_payload(decode=True)
        if not isinstance(payload, bytes):
            return None
        content = payload.decode("utf-8", errors="replace")
    return content if isinstance(content, str) else None


def text_as_html(text: str) -> str:
    """A plain-text issue as paragraphs, so it reads like the HTML kind.

    Blank lines separate paragraphs; the hard line breaks inside one are the
    sender's mailer wrapping at seventy-two columns, not the writer's, and
    are joined back into prose.
    """
    paragraphs = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").replace("\r", "\n")):
        joined = _WHITESPACE.sub(" ", block).strip()
        if joined:
            paragraphs.append(f"<p>{escape(joined)}</p>")
    return "\n".join(paragraphs)
