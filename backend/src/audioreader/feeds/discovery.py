"""Find the real feed behind whatever URL — or spoken name — we were given.

People paste homepages, not feed URLs. Given any URL this module fetches it,
and if it is not itself a feed, looks for one the way browsers used to: the
page's <link rel="alternate"> tags first, then the paths every blog engine
uses by convention.

Given only a spoken name ("subscribe to Astral Codex Ten"), an LLM proposes
candidate sites — searching the web when it does not already know the
publication — and each candidate is fetched, resolved, and checked against
what she actually said before anything is trusted.
"""

import logging
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urljoin

from pydantic import BaseModel, Field, ValidationError

from audioreader.feeds.fetcher import FeedFetchError, fetch_feed, fetch_feed_bytes
from audioreader.feeds.parser import FeedParseError, ParsedFeed, parse_feed
from audioreader.feeds.search import loosely_identifies, meaningful_words
from audioreader.llm.client import LLMClient, LLMError

logger = logging.getLogger(__name__)

#: Where blog engines put their feed when the page does not say. Ordered by
#: how common they are: WordPress, generic, then the static-site generators.
COMMON_FEED_PATHS = ("/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml")

#: Hard cap on candidate fetches per resolution, so one bad page cannot turn
#: into a crawl.
MAX_CANDIDATES = 8

_FEED_MIME_TYPES = {"application/rss+xml", "application/atom+xml"}


def _looks_like_html(text: str) -> bool:
    head = text[:2048].casefold()
    return "<html" in head or "<!doctype html" in head


class _FeedLinkFinder(HTMLParser):
    """Collects <link rel="alternate" type="application/rss+xml" href=…>."""

    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "link":
            return
        by_name = {name: (value or "") for name, value in attrs}
        if "alternate" not in by_name.get("rel", "").lower():
            return
        if by_name.get("type", "").split(";")[0].strip().lower() not in _FEED_MIME_TYPES:
            return
        if href := by_name.get("href"):
            self.hrefs.append(href)


def feed_links_in_html(html: str, base_url: str) -> list[str]:
    """The feed URLs a page advertises, absolute, in page order."""
    finder = _FeedLinkFinder()
    try:
        finder.feed(html)
        finder.close()
    except Exception:  # noqa: BLE001 - broken markup must never break discovery
        pass
    seen: set[str] = set()
    links = []
    for href in finder.hrefs:
        absolute = urljoin(base_url, href)
        if absolute not in seen:
            seen.add(absolute)
            links.append(absolute)
    return links


async def resolve_feed(url: str) -> tuple[str, ParsedFeed]:
    """The feed at (or advertised by) `url`: its canonical URL and its content.

    Raises FeedFetchError when the URL itself is unreachable, FeedParseError
    when it is reachable but no feed can be found through it.
    """
    raw, final_url = await fetch_feed(url)
    html = raw.decode("utf-8", errors="ignore")
    try:
        parsed = parse_feed(raw)
        # feedparser salvages an HTML page's <title> as a "feed" with no
        # items. A titled but empty parse of an HTML document is a web page,
        # and the real feed is whatever that page advertises.
        if parsed.items or not _looks_like_html(html):
            return url, parsed
    except FeedParseError:
        pass

    # Candidates resolve against where the page actually came from, not what
    # was typed: astralcodexten.com redirects to www., and its "/feed" link
    # only exists on the www host.
    candidates = feed_links_in_html(html, base_url=final_url)
    candidates += [urljoin(final_url, path) for path in COMMON_FEED_PATHS]

    tried: set[str] = set()
    for candidate in candidates:
        if candidate in tried or candidate == url:
            continue
        tried.add(candidate)
        if len(tried) > MAX_CANDIDATES:
            break
        try:
            return candidate, parse_feed(await fetch_feed_bytes(candidate))
        except (FeedFetchError, FeedParseError):
            continue
    raise FeedParseError(f"no RSS or Atom feed found at {url}")


FEED_DISCOVERY_PROMPT = """You find the RSS feed for a publication a blind \
listener asked for by name. Publications include blogs, newsletters, Substacks, \
magazines and news sites as well as podcasts.

Given the name as she spoke it, reply with the publication's canonical name and \
up to six URLs where its feed is most likely to be found, best guess first. \
Search the web for the publication's website if you are not certain of it. \
Prefer the feed URL itself when you know it; a homepage is also fine — its \
advertised feed will be found automatically. Substack publications expose \
their feed at https://NAME.substack.com/feed.

Speech recognition may have transcribed the name imperfectly; consider what \
similarly-sounding publication she plausibly meant. Only suggest URLs for the \
publication she named — an empty list is far better than an unrelated site. \
Take your time: this lookup happens once, and a wrong feed subscribes her to a \
stranger's writing."""


class FeedCandidates(BaseModel):
    """What the discovery model is allowed to answer."""

    publication: str = Field(description="The publication's canonical name, or empty if unknown.")
    urls: list[str] = Field(
        description="Up to six candidate feed or homepage URLs, most likely first."
    )


@dataclass
class DiscoveredFeed:
    feed_url: str
    title: str


def substack_guesses(query: str) -> list[str]:
    """Candidate Substack URLs for a name spoken with the word "substack".

    "Liam Halligan's substack" is liamhalligan.substack.com — guessing the
    subdomain directly resolves the most common request in about a second,
    with no model call at all. Wrong guesses cost one failed fetch; every
    guess still goes through fetch, parse and name verification.
    """
    words = meaningful_words(query)
    if "substack" not in query.casefold() or not words:
        return []
    slugs = ["".join(words)]
    if len(words) > 1:
        slugs.append("-".join(words))
    return [f"https://{slug}.substack.com/feed" for slug in slugs]


async def find_feed_by_name(query: str, llm: LLMClient) -> DiscoveredFeed | None:
    """A verified feed for a spoken publication name, or None.

    Every candidate — guessed or model-proposed — is fetched and parsed, and
    the feed is accepted only when what she said identifies it (its title,
    the model's canonical name for it, or its URL). Two model attempts: the
    second reports the failed URLs so the model searches differently.
    """
    tried: list[str] = []
    # Deterministic guesses first: cheap, instant, and they cover the
    # "so-and-so's substack" phrasing that directories never know.
    for guess in substack_guesses(query):
        tried.append(guess)
        try:
            feed_url, parsed = await resolve_feed(guess)
        except (FeedFetchError, FeedParseError):
            continue
        if loosely_identifies(query, f"{parsed.title} {feed_url}"):
            return DiscoveredFeed(feed_url=feed_url, title=parsed.title)

    for _attempt in range(2):
        prompt = f'She said: "{query}"'
        if tried:
            prompt += (
                "\n\nThese URLs were already tried and no matching feed was found "
                "through them: " + ", ".join(tried) + ". Search the web for the "
                "publication's own website and suggest different URLs."
            )
        try:
            raw = await llm.decide(
                system=FEED_DISCOVERY_PROMPT, user=prompt, output_model=FeedCandidates
            )
            candidates = FeedCandidates.model_validate(raw)
        except (LLMError, ValidationError) as exc:
            logger.warning("feed discovery failed for %r: %s", query, exc)
            return None

        for url in candidates.urls[:6]:
            url = url.strip()
            if not url.startswith(("http://", "https://")):
                url = f"https://{url}"
            if url in tried:
                continue
            tried.append(url)
            try:
                feed_url, parsed = await resolve_feed(url)
            except (FeedFetchError, FeedParseError):
                continue
            # The guard against a confidently wrong model: the feed counts
            # only if what she said identifies it. Loose matching, because
            # names appear glued together in URLs ("liamhalligan").
            haystack = f"{parsed.title} {candidates.publication} {feed_url}"
            if loosely_identifies(query, haystack):
                return DiscoveredFeed(feed_url=feed_url, title=parsed.title)
            logger.info(
                "discovery candidate %s (%r) does not match %r", feed_url, parsed.title, query
            )
    return None
