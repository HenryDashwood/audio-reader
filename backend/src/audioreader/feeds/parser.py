"""Turn raw RSS, Atom or JSON Feed bytes into clean, typed feed data.

feedparser tolerates the malformed XML that real feeds are full of; this module
wraps it so the rest of the codebase only ever sees validated Pydantic models.
JSON Feed is small enough to parse directly, and doing so keeps the same typed
shape for every syndication format.
"""

import json
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
    #: Who wrote it, kept separately from the containing feed's title.
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
    self_url: str | None = None
    format: str = "rss"
    # Internal discovery state. It lets a cached candidate carry a website
    # fallback into ingestion without exposing new fields in the API.
    site_artwork_url: str | None = None
    site_artwork_checked: bool = False
    items: list[ParsedItem]


def parse_feed(raw: bytes) -> ParsedFeed:
    if raw.lstrip().startswith((b"{", b"[")):
        return _parse_json_feed(raw)

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
        self_url=_self_link(parsed.feed),
        format=_xml_format(parsed.version),
        items=[
            item for entry in parsed.entries[:MAX_FEED_ITEMS] if (item := _parse_entry(entry, feed_author)) is not None
        ],
    )


def _parse_json_feed(raw: bytes) -> ParsedFeed:
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FeedParseError("input does not look like an RSS, Atom or JSON feed") from exc
    if not isinstance(document, dict) or not str(document.get("version", "")).startswith(
        "https://jsonfeed.org/version/"
    ):
        raise FeedParseError("input does not look like a JSON Feed")

    raw_items = document.get("items")
    if not isinstance(raw_items, list):
        raw_items = []
    feed_author = _json_author(document)
    items = [
        item
        for source in raw_items[:MAX_FEED_ITEMS]
        if isinstance(source, dict) and (item := _parse_json_item(source, feed_author)) is not None
    ]
    return ParsedFeed(
        title=_bounded(document.get("title"), MAX_TITLE_CHARS) or "Untitled feed",
        description=_bounded(document.get("description"), MAX_DESCRIPTION_CHARS),
        author=feed_author,
        image_url=_bounded(document.get("icon") or document.get("favicon"), MAX_URL_CHARS),
        site_url=_bounded(document.get("home_page_url"), MAX_URL_CHARS),
        self_url=_bounded(document.get("feed_url"), MAX_URL_CHARS),
        format="json",
        items=items,
    )


def _parse_json_item(source: dict, feed_author: str | None) -> ParsedItem | None:
    audio_url = None
    duration_seconds = None
    for attachment in source.get("attachments") or []:
        if not isinstance(attachment, dict) or not str(attachment.get("mime_type", "")).startswith("audio/"):
            continue
        audio_url = _bounded(attachment.get("url"), MAX_URL_CHARS)
        duration = attachment.get("duration_in_seconds")
        duration_seconds = int(duration) if isinstance(duration, (int, float)) and duration >= 0 else None
        if audio_url:
            break

    guid = source.get("id") or source.get("url") or source.get("external_url") or audio_url
    if guid is None:
        return None
    content_text = _bounded(source.get("content_text"), MAX_DESCRIPTION_CHARS)
    return ParsedItem(
        guid=_bounded(guid, MAX_URL_CHARS) or "",
        title=_bounded(source.get("title"), MAX_TITLE_CHARS) or "Untitled",
        description=_bounded(source.get("summary"), MAX_DESCRIPTION_CHARS) or content_text,
        content_html=_bounded(source.get("content_html"), MAX_CONTENT_CHARS),
        author=_json_author(source) or feed_author,
        audio_url=audio_url,
        duration_seconds=duration_seconds,
        published_at=_json_date(source.get("date_published") or source.get("date_modified")),
        link=_bounded(source.get("url") or source.get("external_url"), MAX_URL_CHARS),
        image_url=_bounded(source.get("image") or source.get("banner_image"), MAX_URL_CHARS),
    )


def _json_author(source: dict) -> str | None:
    authors = source.get("authors")
    if isinstance(authors, list):
        for author in authors:
            if isinstance(author, dict) and (name := _bounded(author.get("name"), MAX_TITLE_CHARS)):
                return name
    author = source.get("author")
    if isinstance(author, dict):
        return _bounded(author.get("name"), MAX_TITLE_CHARS)
    return None


def _json_date(value: object | None) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def _self_link(feed: feedparser.util.FeedParserDict) -> str | None:
    for link in feed.get("links", []):
        if str(link.get("rel", "")).casefold() == "self" and link.get("href"):
            return _bounded(link["href"], MAX_URL_CHARS)
    return None


def _xml_format(version: str) -> str:
    return "atom" if version.casefold().startswith("atom") else "rss"


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
