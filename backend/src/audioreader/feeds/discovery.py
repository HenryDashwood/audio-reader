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

import asyncio
import ipaddress
import logging
import re
from collections import OrderedDict
from dataclasses import dataclass, replace
from html.parser import HTMLParser
from time import monotonic
from urllib.parse import urljoin, urlsplit, urlunsplit

from pydantic import BaseModel, Field, ValidationError

from audioreader.feeds.artwork import supplement_feed_artwork, supplement_feed_artwork_from_html
from audioreader.feeds.fetcher import (
    FeedFetchError,
    FeedRateLimitedError,
    FeedResolutionError,
    fetch_feed_resource,
)
from audioreader.feeds.parser import FeedParseError, ParsedFeed, parse_feed
from audioreader.feeds.search import (
    PodcastSearchError,
    feed_for_shared_link,
    loosely_identifies,
    meaningful_words,
)
from audioreader.llm.client import LLMClient, LLMError

logger = logging.getLogger(__name__)

#: Where blog engines put their feed when the page does not say. Ordered by
#: how common they are: WordPress, generic, then the static-site generators.
COMMON_FEED_PATHS = (
    "/feed",
    "/feed/",
    "/rss",
    "/rss/",
    "/feed.xml",
    "/rss.xml",
    "/atom.xml",
    "/index.xml",
    "/feed.json",
)

# Some sites put a browser challenge in front of their homepage while leaving
# their RSS endpoint public. A blocked origin page should not prevent the
# deterministic, bounded guesses below; other failures (especially 429s and
# network errors) still stop discovery so we do not amplify an upstream issue.
BLOCKED_HOMEPAGE_STATUSES = {401, 403}

#: Hard cap on candidate fetches per resolution, so one bad page cannot turn
#: into a crawl.
MAX_CANDIDATES = 12
DISCOVERY_DEADLINE_SECONDS = 25
DISCOVERY_CONCURRENCY = 3
SAME_ORIGIN_PROBE_DELAY_SECONDS = 0.2
DISCOVERY_CACHE_SECONDS = 15 * 60
DISCOVERY_NEGATIVE_CACHE_SECONDS = 45
DISCOVERY_CACHE_ENTRIES = 256

_FEED_MIME_TYPES = {
    "application/rss+xml",
    "application/atom+xml",
    "application/feed+json",
}


def _looks_like_html(text: str) -> bool:
    head = text[:2048].casefold()
    return "<html" in head or "<!doctype html" in head


@dataclass(frozen=True)
class AdvertisedFeedLink:
    url: str
    mime_type: str
    title: str | None
    source: str


class _FeedLinkFinder(HTMLParser):
    """Collect feed links from the trusted metadata portion of an HTML page."""

    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str, str | None]] = []
        self.base_href: str | None = None
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
        if tag != "link":
            return
        if "alternate" not in by_name.get("rel", "").casefold().split():
            return
        mime_type = by_name.get("type", "").split(";")[0].strip().casefold()
        if mime_type not in _FEED_MIME_TYPES:
            return
        if href := by_name.get("href"):
            self.links.append((href, mime_type, by_name.get("title") or None))


def advertised_feed_links_in_html(html: str, base_url: str) -> list[AdvertisedFeedLink]:
    """Feed metadata from an HTML head, respecting its first ``<base>``."""

    finder = _FeedLinkFinder()
    try:
        finder.feed(html)
        finder.close()
    except Exception:  # noqa: BLE001 - broken markup must never break discovery
        pass
    resolution_base = urljoin(base_url, finder.base_href) if finder.base_href else base_url
    seen: set[str] = set()
    links = []
    for href, mime_type, title in finder.links:
        absolute = urljoin(resolution_base, href)
        key = _feed_key(absolute)
        if key in seen:
            continue
        seen.add(key)
        links.append(AdvertisedFeedLink(url=absolute, mime_type=mime_type, title=title, source="html"))
    return links


def feed_links_in_html(html: str, base_url: str) -> list[str]:
    """The feed URLs a page advertises, absolute, in page order."""
    return [link.url for link in advertised_feed_links_in_html(html, base_url)]


def feed_links_in_headers(headers: tuple[str, ...], base_url: str) -> list[AdvertisedFeedLink]:
    """RSS/Atom/JSON Feed alternates advertised through HTTP Link headers."""

    links = []
    seen: set[str] = set()
    for header in headers:
        for value in _split_link_values(header):
            match = re.match(r"\s*<([^>]*)>(.*)$", value)
            if not match:
                continue
            params = {
                key.casefold(): quoted or bare or ""
                for key, quoted, bare in re.findall(
                    r";\s*([A-Za-z][\w-]*)\s*=\s*(?:\"([^\"]*)\"|([^;,\s]+))",
                    match.group(2),
                )
            }
            if "alternate" not in params.get("rel", "").casefold().split():
                continue
            mime_type = params.get("type", "").split(";")[0].strip().casefold()
            if mime_type not in _FEED_MIME_TYPES:
                continue
            absolute = urljoin(base_url, match.group(1))
            key = _feed_key(absolute)
            if key in seen:
                continue
            seen.add(key)
            links.append(
                AdvertisedFeedLink(
                    url=absolute,
                    mime_type=mime_type,
                    title=params.get("title") or None,
                    source="http_header",
                )
            )
    return links


def _split_link_values(header: str) -> list[str]:
    values = []
    start = 0
    quoted = False
    angled = False
    for index, character in enumerate(header):
        if character == '"':
            quoted = not quoted
        elif not quoted and character == "<":
            angled = True
        elif not quoted and character == ">":
            angled = False
        elif character == "," and not quoted and not angled:
            values.append(header[start:index])
            start = index + 1
    values.append(header[start:])
    return values


@dataclass(frozen=True)
class FeedCandidate:
    feed_url: str
    title: str
    description: str | None
    site_url: str | None
    format: str
    item_count: int
    audio_item_count: int
    recent_item_titles: tuple[str, ...]
    source: str
    is_primary: bool = False
    # Internal only: the public discovery schema deliberately stays unchanged.
    site_artwork_url: str | None = None
    site_artwork_checked: bool = False


@dataclass(frozen=True)
class _ResolvedCandidate:
    candidate: FeedCandidate
    parsed: ParsedFeed
    base_score: int


@dataclass(frozen=True)
class _CandidateLocation:
    url: str
    source: str
    title: str | None
    order: int


@dataclass(frozen=True)
class _CacheEntry:
    expires_at: float
    candidates: tuple[FeedCandidate, ...] = ()
    error_code: str | None = None
    error_message: str | None = None


class FeedDiscoveryError(FeedParseError):
    def __init__(self, message: str, *, code: str = "no_feed_found") -> None:
        super().__init__(message)
        self.code = code


class FeedDiscoveryTimeout(FeedDiscoveryError):
    def __init__(self) -> None:
        super().__init__(
            "the site took too long while Hearful looked for its feeds",
            code="discovery_timed_out",
        )


_discovery_cache: OrderedDict[str, _CacheEntry] = OrderedDict()


def clear_discovery_cache() -> None:
    _discovery_cache.clear()


async def discover_feeds(url: str, *, preference: str | None = None) -> list[FeedCandidate]:
    """All distinct feeds advertised by a URL, best candidate first."""

    url = await _shared_link_target(url)
    key = _feed_key(url)
    if cached := _cache_get(key):
        if cached.error_code:
            _raise_cached_error(cached)
        logger.info("feed discovery cache hit for %s (%d candidates)", url, len(cached.candidates))
        return _rank_summaries(list(cached.candidates), preference)

    started = monotonic()
    try:
        resolved = await asyncio.wait_for(
            _discover_uncached(url),
            timeout=DISCOVERY_DEADLINE_SECONDS,
        )
    except TimeoutError as exc:
        raise FeedDiscoveryTimeout() from exc
    except FeedFetchError as exc:
        _cache_error(key, exc.code, str(exc))
        raise
    except FeedDiscoveryError as exc:
        _cache_error(key, exc.code, str(exc))
        raise

    summaries = tuple(candidate.candidate for candidate in resolved)
    _cache_put(key, _CacheEntry(monotonic() + DISCOVERY_CACHE_SECONDS, candidates=summaries))
    for summary in summaries:
        _cache_put(
            _feed_key(summary.feed_url),
            _CacheEntry(
                monotonic() + DISCOVERY_CACHE_SECONDS,
                candidates=(replace(summary, is_primary=True),),
            ),
        )
    logger.info(
        "feed discovery completed for %s in %.3fs (%d candidates; primary source=%s)",
        url,
        monotonic() - started,
        len(summaries),
        summaries[0].source,
    )
    return _rank_summaries(list(summaries), preference)


async def resolve_feed(
    url: str,
    country: str | None = None,
    *,
    preference: str | None = None,
) -> tuple[str, ParsedFeed]:
    """The best feed at (or advertised by) ``url`` and its current content."""

    url = await _shared_link_target(url, country=country)
    key = _feed_key(url)
    if cached := _cache_get(key):
        if cached.error_code:
            _raise_cached_error(cached)
        chosen = _rank_summaries(list(cached.candidates), preference)[0]
        fetched = await fetch_feed_resource(chosen.feed_url)
        if fetched.content is None:
            raise FeedFetchError("the server returned no content")
        parsed = parse_feed(fetched.content)
        if not parsed.image_url and chosen.site_artwork_checked:
            parsed = parsed.model_copy(
                update={
                    "site_artwork_url": chosen.site_artwork_url,
                    "site_artwork_checked": True,
                }
            )
        elif not parsed.image_url:
            parsed = await supplement_feed_artwork(parsed, fetched.final_url)
        return _canonical_feed_url(fetched.final_url, parsed.self_url), parsed

    try:
        resolved = await asyncio.wait_for(_discover_uncached(url), timeout=DISCOVERY_DEADLINE_SECONDS)
    except TimeoutError as exc:
        raise FeedDiscoveryTimeout() from exc
    except FeedFetchError as exc:
        _cache_error(key, exc.code, str(exc))
        raise
    except FeedDiscoveryError as exc:
        _cache_error(key, exc.code, str(exc))
        raise

    summaries = tuple(candidate.candidate for candidate in resolved)
    _cache_put(key, _CacheEntry(monotonic() + DISCOVERY_CACHE_SECONDS, candidates=summaries))
    ranked = _rank_resolved(resolved, preference)
    return ranked[0].candidate.feed_url, ranked[0].parsed


async def _shared_link_target(url: str, country: str | None = None) -> str:
    try:
        return await feed_for_shared_link(url, country=country) or url
    except PodcastSearchError as exc:
        raise FeedFetchError("could not resolve the podcast sharing link") from exc


async def _discover_uncached(url: str) -> list[_ResolvedCandidate]:
    initial_fetch_failure: FeedFetchError | None = None
    try:
        fetched = await fetch_feed_resource(url)
    except FeedResolutionError as exc:
        # A bare domain with no DNS record often exists only at www: Substack
        # custom domains, among others, are set up that way. Retry there, but
        # let a www failure surface the error for the address she typed.
        if (www_url := _www_fallback_url(url)) is None:
            raise
        logger.info("host of %s does not resolve; retrying discovery at %s", url, www_url)
        try:
            return await _discover_uncached(www_url)
        except FeedFetchError:
            raise exc from None
    except FeedFetchError as exc:
        if exc.status_code not in BLOCKED_HOMEPAGE_STATUSES or not _is_origin_homepage(url):
            raise
        # There is no HTML metadata to inspect, but root-relative conventional
        # paths remain safe and useful to try on the already-validated origin.
        initial_fetch_failure = exc
        homepage_url = url
        html = ""
        advertised = []
    else:
        if fetched.content is None:
            raise FeedFetchError("the server returned no content")
        homepage_url = fetched.final_url
        html = fetched.content.decode("utf-8", errors="ignore")
        try:
            parsed = parse_feed(fetched.content)
            if parsed.items or not _looks_like_html(html):
                parsed = await supplement_feed_artwork(parsed, fetched.final_url)
                return [_resolved_candidate(parsed, fetched.final_url, "direct", None, 0)]
        except FeedParseError:
            pass

        advertised = feed_links_in_headers(fetched.link_headers, fetched.final_url)
        advertised += advertised_feed_links_in_html(html, fetched.final_url)
    locations = [_CandidateLocation(link.url, link.source, link.title, order) for order, link in enumerate(advertised)]
    common_locations = [
        _CandidateLocation(urljoin(homepage_url, path), "common_path", None, order)
        for order, path in enumerate(COMMON_FEED_PATHS)
    ]
    # Explicit primary metadata is authoritative and may intentionally
    # advertise several feeds. A page that advertises only comments or replies
    # has not identified its publication feed, though: probe conventional main
    # paths first rather than silently treating discussion as the publication.
    if not locations:
        locations = common_locations
    elif all(_is_secondary_feed_location(location) for location in locations):
        locations = common_locations + [
            replace(location, order=len(common_locations) + index) for index, location in enumerate(locations)
        ]

    unique: list[_CandidateLocation] = []
    seen = {_request_key(homepage_url)}
    for location in locations:
        key = _request_key(location.url)
        if key in seen:
            continue
        seen.add(key)
        unique.append(location)
        if len(unique) == MAX_CANDIDATES:
            break

    # WordPress and other shared hosts commonly rate-limit a burst from one
    # origin. Probe one address at a time per origin, while still allowing
    # genuinely separate feed hosts to proceed concurrently. Main feeds go
    # before comment/response feeds even when a page advertises them first.
    unique.sort(key=_candidate_probe_priority)
    by_origin: OrderedDict[str, list[_CandidateLocation]] = OrderedDict()
    for location in unique:
        by_origin.setdefault(_origin_key(location.url), []).append(location)

    semaphore = asyncio.Semaphore(DISCOVERY_CONCURRENCY)
    fetch_failures: list[FeedFetchError] = [initial_fetch_failure] if initial_fetch_failure else []

    async def inspect(location: _CandidateLocation) -> _ResolvedCandidate | None:
        try:
            result = await fetch_feed_resource(location.url)
            if result.content is None:
                return None
            parsed = parse_feed(result.content)
        except FeedFetchError as exc:
            fetch_failures.append(exc)
            logger.info("feed discovery candidate fetch failed for %s: %s", location.url, exc)
            return None
        except FeedParseError as exc:
            logger.info("feed discovery candidate was not a feed at %s: %s", location.url, exc)
            return None
        parsed = supplement_feed_artwork_from_html(parsed, html, homepage_url)
        return _resolved_candidate(
            parsed,
            result.final_url,
            location.source,
            location.title,
            location.order,
        )

    async def inspect_origin(locations: list[_CandidateLocation]) -> list[_ResolvedCandidate | None]:
        async with semaphore:
            inspected = []
            follows_homepage = _origin_key(locations[0].url) == _origin_key(homepage_url)
            for index, location in enumerate(locations):
                # The homepage itself was just fetched, so leave a small gap
                # before the first same-origin feed as well as between feeds.
                # This is imperceptible in the UI and avoids host burst limits.
                if follows_homepage or index > 0:
                    await asyncio.sleep(SAME_ORIGIN_PROBE_DELAY_SECONDS)
                inspected.append(await inspect(location))
            return inspected

    groups = await asyncio.gather(*(inspect_origin(locations) for locations in by_origin.values()))
    inspected = [candidate for group in groups for candidate in group]
    candidates = _deduplicate_candidates([candidate for candidate in inspected if candidate])
    if not candidates:
        if limited := next(
            (failure for failure in fetch_failures if isinstance(failure, FeedRateLimitedError)),
            None,
        ):
            raise limited
        if unavailable := next(
            (failure for failure in fetch_failures if failure.status_code not in {404, 410}),
            None,
        ):
            raise unavailable
        raise FeedDiscoveryError(f"no RSS, Atom or JSON feed was found at {url}")
    return _rank_resolved(candidates, None)


def _www_fallback_url(url: str) -> str | None:
    """The same URL on the www host, or None when the retry makes no sense.

    Only a plain dotted hostname qualifies: an IP literal, a host already
    under www, or a URL carrying userinfo (rejected by the fetcher anyway)
    has no meaningful www sibling.
    """

    try:
        parsed = urlsplit(url)
    except ValueError:
        return None
    host = parsed.hostname
    if not host or "." not in host or host.startswith("www.") or "@" in parsed.netloc:
        return None
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        return None
    netloc = f"www.{host}:{parsed.port}" if parsed.port is not None else f"www.{host}"
    return urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, ""))


def _is_origin_homepage(url: str) -> bool:
    """Whether ``url`` names an origin root rather than an explicit resource."""

    try:
        return urlsplit(url).path in {"", "/"}
    except ValueError:
        return False


def _candidate_probe_priority(location: _CandidateLocation) -> tuple[bool, int]:
    return _is_secondary_feed_location(location), location.order


def _is_secondary_feed_location(location: _CandidateLocation) -> bool:
    label = f"{location.title or ''} {urlsplit(location.url).path}".casefold()
    return any(word in label for word in ("comment", "repl", "response"))


def _origin_key(url: str) -> str:
    parsed = urlsplit(url)
    return f"{parsed.scheme.casefold()}://{parsed.netloc.casefold()}"


def _resolved_candidate(
    parsed: ParsedFeed,
    final_url: str,
    source: str,
    title_hint: str | None,
    order: int,
) -> _ResolvedCandidate:
    audio_count = sum(item.audio_url is not None for item in parsed.items)
    title = parsed.title or title_hint or "Untitled feed"
    candidate = FeedCandidate(
        feed_url=_canonical_feed_url(final_url, parsed.self_url),
        title=title,
        description=parsed.description,
        site_url=parsed.site_url,
        format=parsed.format,
        item_count=len(parsed.items),
        audio_item_count=audio_count,
        recent_item_titles=tuple(item.title for item in parsed.items[:3]),
        source=source,
        site_artwork_url=parsed.site_artwork_url,
        site_artwork_checked=parsed.site_artwork_checked,
    )
    source_score = {"direct": 1_000, "http_header": 800, "html": 760, "common_path": 400}[source]
    label = f"{title_hint or ''} {title}".casefold()
    penalty = 0
    if any(word in label for word in ("comment", "repl", "response")):
        # Strong enough that a conventional main feed beats an explicitly
        # advertised discussion feed when the publisher omitted main metadata.
        penalty += 500
    if any(word in label for word in ("category", "tag feed", "author feed")):
        penalty += 100
    bonus = 30 if any(word in label for word in ("main", "all posts", "articles")) else 0
    return _ResolvedCandidate(candidate, parsed, source_score + bonus - penalty - order)


def _rank_resolved(candidates: list[_ResolvedCandidate], preference: str | None) -> list[_ResolvedCandidate]:
    ranked = sorted(
        candidates,
        key=lambda candidate: (
            -candidate.base_score - _preference_score(candidate.candidate, preference),
            candidate.candidate.title.casefold(),
        ),
    )
    return [
        replace(candidate, candidate=replace(candidate.candidate, is_primary=index == 0))
        for index, candidate in enumerate(ranked)
    ]


def _rank_summaries(candidates: list[FeedCandidate], preference: str | None) -> list[FeedCandidate]:
    ranked = sorted(
        enumerate(candidates),
        key=lambda pair: (
            -_preference_score(pair[1], preference),
            not pair[1].is_primary,
            pair[0],
        ),
    )
    return [replace(candidate, is_primary=index == 0) for index, (_, candidate) in enumerate(ranked)]


def _preference_score(candidate: FeedCandidate, preference: str | None) -> int:
    if not preference:
        return 0
    words = {word for word in re.sub(r"[^a-z0-9 ]", " ", preference.casefold()).split() if len(word) > 2}
    label = re.sub(r"[^a-z0-9 ]", " ", candidate.title.casefold())
    score = sum(80 for word in words if word in label.split())
    if candidate.audio_item_count and words & {"podcast", "audio", "episodes"}:
        score += 180
    if not candidate.audio_item_count and words & {"article", "articles", "blog", "posts", "writing"}:
        score += 120
    return score


def _deduplicate_candidates(candidates: list[_ResolvedCandidate]) -> list[_ResolvedCandidate]:
    by_url: dict[str, _ResolvedCandidate] = {}
    by_content: dict[tuple[str, tuple[str, ...]], _ResolvedCandidate] = {}
    for candidate in candidates:
        url_key = _feed_key(candidate.candidate.feed_url)
        if url_key in by_url:
            continue
        content_key = (
            candidate.candidate.title.casefold(),
            tuple(item.guid for item in candidate.parsed.items[:3]),
        )
        existing = by_content.get(content_key) if content_key[1] else None
        if existing is not None:
            if candidate.base_score > existing.base_score:
                by_url.pop(_feed_key(existing.candidate.feed_url), None)
                by_url[url_key] = candidate
                by_content[content_key] = candidate
            continue
        by_url[url_key] = candidate
        if content_key[1]:
            by_content[content_key] = candidate
    return list(by_url.values())


def _without_fragment(url: str) -> str:
    parsed = urlsplit(url)
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, parsed.query, ""))


def _canonical_feed_url(final_url: str, self_url: str | None) -> str:
    """Prefer a same-origin ``rel=self`` URL, otherwise the final redirect."""

    final = urlsplit(final_url)
    if self_url:
        candidate_url = urljoin(final_url, self_url)
        try:
            candidate = urlsplit(candidate_url)
            port = candidate.port
        except ValueError:
            candidate = None
        if (
            candidate is not None
            and candidate.scheme in {"http", "https"}
            and candidate.hostname == final.hostname
            and candidate.username is None
            and candidate.password is None
            and port in {None, 80, 443}
        ):
            return _without_fragment(candidate_url)
    return _without_fragment(final_url)


def _feed_key(url: str) -> str:
    parsed = urlsplit(url)
    host = (parsed.hostname or "").casefold()
    try:
        port = parsed.port
    except ValueError:
        return _without_fragment(url)
    authority = host if port in {None, 80, 443} else f"{host}:{port}"
    path = parsed.path.rstrip("/") or "/"
    return urlunsplit(("https", authority, path, parsed.query, ""))


def _request_key(url: str) -> str:
    """A fetch identity that keeps meaningful trailing-slash variants apart."""

    parsed = urlsplit(url)
    return urlunsplit((parsed.scheme.casefold(), parsed.netloc.casefold(), parsed.path, parsed.query, ""))


def _cache_get(key: str) -> _CacheEntry | None:
    entry = _discovery_cache.get(key)
    if entry is None:
        return None
    if entry.expires_at <= monotonic():
        _discovery_cache.pop(key, None)
        return None
    _discovery_cache.move_to_end(key)
    return entry


def _cache_put(key: str, entry: _CacheEntry) -> None:
    _discovery_cache[key] = entry
    _discovery_cache.move_to_end(key)
    while len(_discovery_cache) > DISCOVERY_CACHE_ENTRIES:
        _discovery_cache.popitem(last=False)


def _cache_error(key: str, code: str, message: str) -> None:
    _cache_put(
        key,
        _CacheEntry(
            monotonic() + DISCOVERY_NEGATIVE_CACHE_SECONDS,
            error_code=code,
            error_message=message,
        ),
    )


def _raise_cached_error(entry: _CacheEntry) -> None:
    message = entry.error_message or "feed discovery failed"
    if entry.error_code == FeedRateLimitedError.code:
        raise FeedRateLimitedError(message, status_code=429)
    if entry.error_code == FeedFetchError.code:
        raise FeedFetchError(message)
    raise FeedDiscoveryError(message, code=entry.error_code or "no_feed_found")


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
    urls: list[str] = Field(description="Up to six candidate feed or homepage URLs, most likely first.")


@dataclass
class DiscoveredFeed:
    feed_url: str
    title: str


#: Words that end the run of words belonging to a spoken domain name:
#: "subscribe to the rss feed of astral codex ten dot com" — everything
#: before "of" is command, everything after is domain.
_DOMAIN_STOPWORDS = {
    "the", "a", "an", "of", "to", "at", "on", "for", "from", "and",
    "feed", "feeds", "rss", "website", "site", "blog", "newsletter",
    "articles", "subscribe", "unsubscribe", "play", "add", "follow",
}  # fmt: skip


def spoken_domains(text: str) -> list[str]:
    """Candidate domain names heard in a sentence, most complete first.

    Speech transcribes a domain either literally ("astralcodexten.com") or
    with the name broken into words ("astral codex ten dot com" arrives as
    "astral codex ten.com", where only "ten.com" touches the dot). Preceding
    words are glued on one by one, stopping at command words — so both forms
    yield "astralcodexten.com". Longest first: the most complete join is the
    site she actually named, and callers take the first that resolves.
    """
    cleaned = re.sub(r"\s+dot\s+", ".", text.casefold())
    candidates: list[str] = []
    for match in re.finditer(r"([a-z0-9][a-z0-9-]*(?:\.[a-z]{2,})+)", cleaned):
        base = match.group(1)
        joins = [base]
        joined = base
        for word in reversed(cleaned[: match.start()].split()):
            if word in _DOMAIN_STOPWORDS or not word.isalnum():
                break
            joined = word + joined
            joins.append(joined)
        candidates.extend(reversed(joins))
    seen: set[str] = set()
    unique = [c for c in candidates if not (c in seen or seen.add(c))]
    return unique[:5]


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
            feed_url, parsed = await resolve_feed(guess, preference=query)
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
            raw = await llm.decide(system=FEED_DISCOVERY_PROMPT, user=prompt, output_model=FeedCandidates)
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
                feed_url, parsed = await resolve_feed(url, preference=query)
            except (FeedFetchError, FeedParseError):
                continue
            # The guard against a confidently wrong model: the feed counts
            # only if what she said identifies it. Loose matching, because
            # names appear glued together in URLs ("liamhalligan").
            haystack = f"{parsed.title} {candidates.publication} {feed_url}"
            if loosely_identifies(query, haystack):
                return DiscoveredFeed(feed_url=feed_url, title=parsed.title)
            logger.info("discovery candidate %s (%r) does not match %r", feed_url, parsed.title, query)
    return None
