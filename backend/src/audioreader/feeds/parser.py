"""Turn raw RSS/Atom bytes into clean, typed feed data.

feedparser tolerates the malformed XML that real feeds are full of; this module
wraps it so the rest of the codebase only ever sees validated Pydantic models.
"""

from calendar import timegm
from datetime import UTC, datetime

import feedparser
from pydantic import BaseModel

MAX_FEED_ITEMS = 2_000
MAX_TITLE_CHARS = 1_000
MAX_DESCRIPTION_CHARS = 100_000
MAX_CONTENT_CHARS = 500_000
MAX_URL_CHARS = 4_096


class FeedParseError(Exception):
    """The input could not be interpreted as an RSS/Atom feed."""


class ParsedItem(BaseModel):
    guid: str
    title: str
    description: str | None = None
    content_html: str | None = None
    #: Who wrote it — the byline a reader shows above the first paragraph.
    #: From the item where the feed names one, otherwise from the channel,
    #: which for a one-writer blog is the same person either way.
    author: str | None = None
    audio_url: str | None = None
    duration_seconds: int | None = None
    published_at: datetime | None = None
    link: str | None = None
    image_url: str | None = None


class ParsedFeed(BaseModel):
    title: str
    description: str | None = None
    author: str | None = None
    image_url: str | None = None
    site_url: str | None = None
    items: list[ParsedItem]


def parse_feed(raw: bytes) -> ParsedFeed:
    parsed = feedparser.parse(raw)
    # feedparser almost never raises: it records problems in `bozo` and returns
    # whatever it could salvage. Only reject input when there is no usable feed
    # at all, since many perfectly listenable feeds are technically malformed.
    if not parsed.feed.get("title") and not parsed.entries:
        raise FeedParseError("input does not look like an RSS/Atom feed")

    feed_author = _author(parsed.feed)
    return ParsedFeed(
        title=_bounded(parsed.feed.get("title", "Untitled feed"), MAX_TITLE_CHARS) or "Untitled feed",
        description=_bounded(parsed.feed.get("description"), MAX_DESCRIPTION_CHARS),
        author=feed_author,
        image_url=(parsed.feed.get("image") or {}).get("href"),
        site_url=parsed.feed.get("link"),
        items=[
            item for entry in parsed.entries[:MAX_FEED_ITEMS] if (item := _parse_entry(entry, feed_author)) is not None
        ],
    )


def _parse_entry(entry: feedparser.util.FeedParserDict, feed_author: str | None) -> ParsedItem | None:
    audio_url = _first_audio_enclosure(entry)
    guid = entry.get("id") or entry.get("link") or audio_url
    if guid is None:
        # Without any stable identifier we cannot dedupe this item across
        # polls, so it is safer to skip it than to re-add it every poll.
        return None

    return ParsedItem(
        guid=_bounded(guid, MAX_URL_CHARS) or "",
        title=_bounded(entry.get("title"), MAX_TITLE_CHARS) or "Untitled",
        description=_bounded(entry.get("summary"), MAX_DESCRIPTION_CHARS),
        content_html=_bounded(_content_html(entry), MAX_CONTENT_CHARS),
        author=_author(entry) or feed_author,
        audio_url=audio_url,
        duration_seconds=_parse_duration(entry.get("itunes_duration")),
        published_at=_published_at(entry),
        link=entry.get("link"),
        # feedparser maps a per-item <itunes:image href=…> to entry.image.href.
        image_url=(entry.get("image") or {}).get("href"),
    )


def _bounded(value: object | None, limit: int) -> str | None:
    if value is None:
        return None
    text = str(value)
    return text[:limit] if text else None


def _first_audio_enclosure(entry: feedparser.util.FeedParserDict) -> str | None:
    for enclosure in entry.get("enclosures", []):
        href = enclosure.get("href")
        if href and enclosure.get("type", "").startswith("audio/"):
            return href
    return None


def _content_html(entry: feedparser.util.FeedParserDict) -> str | None:
    for content in entry.get("content", []):
        if content.get("type") == "text/html" and content.get("value"):
            return content["value"]
    return None


def _author(source: feedparser.util.FeedParserDict) -> str | None:
    """A byline, not a mailbox.

    RSS specifies <author> as an email address with the writer's name in
    brackets after it, so a great many feeds put "noreply@example.com (Jane
    Doe)" where a person's name belongs. feedparser splits that apart into
    author_detail.name, which is the half worth showing above an article; a
    bare address is nobody's byline, so it is dropped rather than displayed.
    """
    name = (source.get("author_detail") or {}).get("name")
    byline = (name or source.get("author") or "").strip()
    if not byline or "@" in byline:
        return None
    return byline


def _parse_duration(value: str | None) -> int | None:
    """iTunes duration is either plain seconds ("3125") or clock form ("1:02:03")."""
    if not value:
        return None
    parts = value.strip().split(":")
    try:
        numbers = [int(part) for part in parts]
    except ValueError:
        return None
    if len(numbers) > 3:
        return None
    seconds = 0
    for number in numbers:
        seconds = seconds * 60 + number
    return seconds


def _published_at(entry: feedparser.util.FeedParserDict) -> datetime | None:
    # feedparser normalises every date format it understands into a UTC
    # struct_time, which saves us from parsing RFC 822 dates ourselves.
    parsed = entry.get("published_parsed") or entry.get("updated_parsed")
    if parsed is None:
        return None
    return datetime.fromtimestamp(timegm(parsed), tz=UTC)
