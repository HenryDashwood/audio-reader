"""Best-effort feed artwork from a publication's website metadata.

RSS artwork is optional, and article feeds omit it much more often than
podcasts do.  A publication's HTML head usually still names a social card or
favicon, so use that as a display fallback without crawling page content.
"""

import logging
from datetime import UTC, datetime, timedelta
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

from audioreader.feeds.fetcher import MAX_ARTICLE_BYTES, fetch_public_bytes
from audioreader.feeds.parser import MAX_URL_CHARS, ParsedFeed

logger = logging.getLogger(__name__)

SITE_ARTWORK_RECHECK_AFTER = timedelta(days=30)


class _ArtworkFinder(HTMLParser):
    """Read image metadata from the head, never from user-authored body HTML."""

    def __init__(self) -> None:
        super().__init__()
        self.base_href: str | None = None
        self.open_graph: list[str] = []
        self.twitter: list[str] = []
        #: (href, mime type, largest declared side in pixels, or None)
        self.touch_icons: list[tuple[str, str, int | None]] = []
        self.icons: list[tuple[str, str, int | None]] = []
        self.in_body = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.casefold()
        if tag == "body":
            self.in_body = True
            return
        if self.in_body:
            return

        by_name = {name.casefold(): (value or "") for name, value in attrs}
        if tag == "base" and self.base_href is None and by_name.get("href"):
            self.base_href = by_name["href"]
            return

        if tag == "meta":
            key = (by_name.get("property") or by_name.get("name") or "").casefold()
            content = by_name.get("content")
            if not content:
                return
            if key in {"og:image", "og:image:url", "og:image:secure_url"}:
                self.open_graph.append(content)
            elif key in {"twitter:image", "twitter:image:src"}:
                self.twitter.append(content)
            return

        if tag != "link" or not (href := by_name.get("href")):
            return
        rels = set(by_name.get("rel", "").casefold().split())
        candidate = (href, by_name.get("type", "").split(";")[0].casefold(), _largest_side(by_name.get("sizes", "")))
        if any(rel.startswith("apple-touch-icon") for rel in rels):
            self.touch_icons.append(candidate)
        elif "icon" in rels:
            self.icons.append(candidate)


def _largest_side(sizes: str) -> int | None:
    """The biggest pixel side a `sizes` attribute declares, if it says."""
    sides = []
    for token in sizes.casefold().split():
        width, _, height = token.partition("x")
        if width.isdigit() and height.isdigit():
            sides.append(max(int(width), int(height)))
    return max(sides) if sides else None


#: A touch icon this large is a square identity mark, drawn for exactly the
#: tile it is going into. Smaller icons are favicons: last resort.
_TILE_SIDE = 120


def artwork_url_in_html(html: str, page_url: str) -> str | None:
    """The best raster artwork named by an HTML head, made absolute.

    A show's artwork is a square tile, so a large touch icon — the site's
    own square mark — comes first. The social card is next: a photo that
    happened to illustrate the front page as often as a logo. Small icons
    are favicons and come last.
    """

    finder = _ArtworkFinder()
    try:
        finder.feed(html)
        finder.close()
    except Exception:  # Broken publisher markup must not stop feed ingestion.
        pass

    base_url = urljoin(page_url, finder.base_href) if finder.base_href else page_url
    by_size = sorted(finder.touch_icons + finder.icons, key=lambda icon: icon[2] or 0, reverse=True)
    marks = [icon for icon in finder.touch_icons if icon[2] is None or icon[2] >= _TILE_SIDE]
    marks += [icon for icon in finder.icons if icon[2] is not None and icon[2] >= _TILE_SIDE]
    marks.sort(key=lambda icon: icon[2] or _TILE_SIDE, reverse=True)
    candidates = [
        *((icon[0], icon[1]) for icon in marks),
        *((url, "") for url in finder.open_graph),
        *((url, "") for url in finder.twitter),
        *((icon[0], icon[1]) for icon in by_size if icon not in marks),
    ]
    for candidate, mime_type in candidates:
        if mime_type == "image/svg+xml" or urlsplit(candidate).path.casefold().endswith(".svg"):
            # SwiftUI's AsyncImage does not render SVG artwork.
            continue
        if usable := _usable_image_url(urljoin(base_url, candidate)):
            return usable
    return None


def _usable_image_url(url: str) -> str | None:
    if not url or len(url) > MAX_URL_CHARS:
        return None
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme.casefold() not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 80, 443}
    ):
        return None
    return url


async def website_artwork_url(site_url: str | None, feed_url: str) -> str | None:
    """Fetch one bounded public homepage and return its preferred artwork."""

    if not site_url:
        return None
    target = urljoin(feed_url, site_url)
    if _request_key(target) == _request_key(feed_url):
        return None
    try:
        content, final_url = await fetch_public_bytes(target, max_bytes=MAX_ARTICLE_BYTES)
    except Exception as exc:  # Optional metadata must never make a healthy feed fail.
        logger.info("website artwork fetch failed for %s: %s", target, exc)
        return None
    return artwork_url_in_html(content.decode("utf-8", errors="ignore"), final_url)


async def supplement_feed_artwork(parsed: ParsedFeed, feed_url: str) -> ParsedFeed:
    """Add website artwork when the feed itself did not declare any."""

    if parsed.image_url:
        return parsed
    fallback = await website_artwork_url(parsed.site_url, feed_url)
    return parsed.model_copy(
        update={
            "site_artwork_url": fallback,
            "site_artwork_checked": True,
        }
    )


def supplement_feed_artwork_from_html(parsed: ParsedFeed, html: str, page_url: str) -> ParsedFeed:
    """Reuse a homepage already fetched while discovering its feed."""

    if parsed.image_url:
        return parsed
    fallback = artwork_url_in_html(html, page_url)
    return parsed.model_copy(
        update={
            "site_artwork_url": fallback,
            "site_artwork_checked": True,
        }
    )


def site_artwork_is_due(checked_at: datetime | None, *, now: datetime | None = None) -> bool:
    """Occasionally retry sites that had no usable artwork or were unavailable."""

    if checked_at is None:
        return True
    if checked_at.tzinfo is None:
        checked_at = checked_at.replace(tzinfo=UTC)
    return checked_at <= (now or datetime.now(UTC)) - SITE_ARTWORK_RECHECK_AFTER


def _request_key(url: str) -> tuple[str, str, int | None, str, str]:
    """Enough URL identity to avoid fetching a feed again as its own homepage."""

    try:
        parsed = urlsplit(url)
        return (
            parsed.scheme.casefold(),
            (parsed.hostname or "").casefold(),
            parsed.port,
            parsed.path or "/",
            parsed.query,
        )
    except ValueError:
        return "", "", None, url, ""
