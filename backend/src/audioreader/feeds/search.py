"""Find podcasts through Apple's public directory.

The directory is deliberately only one search source. This module makes that
source dependable enough to sit behind typed and spoken search: requests are
cached and coalesced, temporary failures are retried, malformed rows ignored,
aliases deduplicated, and ranking is ours rather than blindly trusting the
order Apple happened to return.
"""

import asyncio
import re
import time
import unicodedata
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from urllib.parse import urlsplit, urlunsplit

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from audioreader.ratelimit import SlidingWindow

SEARCH_URL = "https://itunes.apple.com/search"
LOOKUP_URL = "https://itunes.apple.com/lookup"

# Apple's published guidance describes an approximate twenty-call-per-minute
# limit per public address. Keep two calls in reserve for retries and other
# processes sharing the address. Cache hits never touch this window.
_UPSTREAM_LIMIT = 18
_CACHE_SECONDS = 5 * 60
_STALE_SECONDS = 24 * 60 * 60
_MAX_CACHE_ENTRIES = 256
_RETRY_DELAYS = (0.15, 0.4)


class PodcastSearchError(Exception):
    """The podcast directory could not be searched."""


class PodcastMatch(BaseModel):
    title: str
    feed_url: str
    publisher: str | None = None
    episode_count: int | None = None
    artwork_url: str | None = None
    itunes_id: int | None = None
    country: str | None = None
    primary_genre: str | None = None
    latest_release_date: datetime | None = None


class _ApplePodcast(BaseModel):
    """The small, validated subset of an Apple result that Magpie uses."""

    model_config = ConfigDict(extra="ignore")

    title: str | None = Field(default=None, validation_alias="collectionName")
    feed_url: str | None = Field(default=None, validation_alias="feedUrl")
    publisher: str | None = Field(default=None, validation_alias="artistName")
    episode_count: int | None = Field(default=None, validation_alias="trackCount")
    artwork_600: str | None = Field(default=None, validation_alias="artworkUrl600")
    artwork_100: str | None = Field(default=None, validation_alias="artworkUrl100")
    itunes_id: int | None = Field(default=None, validation_alias="collectionId")
    country: str | None = None
    primary_genre: str | None = Field(default=None, validation_alias="primaryGenreName")
    latest_release_date: datetime | None = Field(default=None, validation_alias="releaseDate")


class _AppleResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")

    results: list[_ApplePodcast] = Field(default_factory=list)


@dataclass(frozen=True)
class _CacheEntry:
    matches: tuple[PodcastMatch, ...]
    fresh_until: float
    stale_until: float


_cache: dict[tuple[object, ...], _CacheEntry] = {}
_in_flight: dict[tuple[object, ...], asyncio.Task[list[PodcastMatch]]] = {}
_upstream_window = SlidingWindow(_UPSTREAM_LIMIT, window_seconds=60)


def clear_podcast_search_state() -> None:
    """Reset process-local state. Primarily the isolation seam used by tests."""

    global _upstream_window
    _cache.clear()
    for task in _in_flight.values():
        task.cancel()
    _in_flight.clear()
    _upstream_window = SlidingWindow(_UPSTREAM_LIMIT, window_seconds=60)


async def search_podcasts(
    query: str,
    limit: int = 5,
    strict: bool = True,
    country: str | None = None,
) -> list[PodcastMatch]:
    """Search and return Magpie-ranked, deduplicated directory matches.

    ``strict=True`` is the voice path: every meaningful word must plausibly
    match the title or publisher, because acting on a wrong result is worse
    than showing a loose one. A one-edit allowance covers ordinary typing
    errors and adjacent transpositions in transcripts.
    """

    query = query.strip()
    if not query:
        return []
    country = _country_code(country)
    key = ("search", _normalise(query), limit, country)
    params = {"term": query, "entity": "podcast", "limit": str(limit)}
    if country:
        params["country"] = country
    matches = await _cached_request(key, lambda: _apple_request(SEARCH_URL, params))
    return _prepare(matches, query, strict=strict)


async def podcast_for_itunes_id(itunes_id: int, country: str | None = None) -> PodcastMatch | None:
    """Resolve an Apple Podcasts identifier to its public RSS feed."""

    country = _country_code(country)
    key = ("lookup", itunes_id, country)
    params = {"id": str(itunes_id), "entity": "podcast"}
    if country:
        params["country"] = country
    matches = await _cached_request(key, lambda: _apple_request(LOOKUP_URL, params))
    return next((match for match in matches if match.itunes_id in {None, itunes_id}), None)


async def feed_for_shared_link(url: str, country: str | None = None) -> str | None:
    """Return the RSS URL encoded by a supported directory sharing link.

    Apple share links contain the stable collection id even when their human
    slug changes. Episode links carry an additional ``?i=`` id; the id in the
    path remains the containing podcast and is the one we need.
    """

    try:
        parsed = urlsplit(url)
    except ValueError:
        return None
    host = (parsed.hostname or "").casefold().removeprefix("www.")
    if host not in {"podcasts.apple.com", "itunes.apple.com"}:
        return None
    match = re.search(r"(?:^|/)id(\d+)(?:/|$)", parsed.path)
    if match is None:
        return None
    storefront = next(
        (part for part in parsed.path.split("/") if len(part) == 2 and part.isalpha()),
        None,
    )
    podcast = await podcast_for_itunes_id(int(match.group(1)), country=country or storefront)
    return podcast.feed_url if podcast else None


def select_unambiguous_match(matches: list[PodcastMatch], query: str) -> PodcastMatch | None:
    """Return a voice-safe winner, or ``None`` when she must be asked.

    One surviving result is safe. With several, only a unique exact title or
    unique all-words-in-title match wins; a generic word such as "history"
    must never silently subscribe to whichever result appeared first.
    """

    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    target = _identity(query)
    exact = [match for match in matches if _identity(match.title) == target]
    if len(exact) == 1:
        return exact[0]
    words = _identifying_words(query)
    title_matches = [
        match for match in matches if words and all(_word_in(word, _words(match.title)) for word in words)
    ]
    return title_matches[0] if len(words) >= 2 and len(title_matches) == 1 else None


async def _cached_request(
    key: tuple[object, ...],
    request: Callable[[], Awaitable[list[PodcastMatch]]],
) -> list[PodcastMatch]:
    now = time.monotonic()
    cached = _cache.get(key)
    if cached is not None and cached.fresh_until > now:
        return list(cached.matches)

    task = _in_flight.get(key)
    if task is None:
        task = asyncio.create_task(_request_and_cache(key, request))
        _in_flight[key] = task
        task.add_done_callback(lambda completed: _request_finished(key, completed))
    try:
        matches = await asyncio.shield(task)
    except PodcastSearchError:
        # A recently useful answer is better than making an outage erase the
        # result list. Preview still validates the feed before it can be used.
        if cached is not None and cached.stale_until > now:
            return list(cached.matches)
        raise
    return list(matches)


async def _request_and_cache(
    key: tuple[object, ...],
    request: Callable[[], Awaitable[list[PodcastMatch]]],
) -> list[PodcastMatch]:
    matches = await request()
    completed = time.monotonic()
    _cache[key] = _CacheEntry(
        matches=tuple(matches),
        fresh_until=completed + _CACHE_SECONDS,
        stale_until=completed + _STALE_SECONDS,
    )
    if len(_cache) > _MAX_CACHE_ENTRIES:
        oldest = min(_cache, key=lambda item: _cache[item].fresh_until)
        _cache.pop(oldest, None)
    return list(matches)


def _request_finished(key: tuple[object, ...], task: asyncio.Task[list[PodcastMatch]]) -> None:
    """Release coalescing state even when every waiting keystroke was cancelled."""

    if _in_flight.get(key) is task:
        _in_flight.pop(key, None)
    # Retrieving an unobserved exception prevents asyncio from logging it when
    # all callers were cancelled while the shared upstream request continued.
    if not task.cancelled():
        task.exception()


async def _apple_request(url: str, params: dict[str, str]) -> list[PodcastMatch]:
    last_error: Exception | None = None
    async with httpx.AsyncClient(timeout=15) as client:
        for attempt in range(len(_RETRY_DELAYS) + 1):
            decision = _upstream_window.check("apple")
            if not decision.allowed:
                raise PodcastSearchError(f"podcast directory is busy; retry in {decision.retry_after} seconds")
            try:
                response = await client.get(url, params=params)
                response.raise_for_status()
                try:
                    body = _AppleResponse.model_validate(response.json())
                except (ValueError, ValidationError) as exc:
                    raise PodcastSearchError("podcast directory returned invalid data") from exc
                return _matches(body)
            except (httpx.TransportError, httpx.HTTPStatusError) as exc:
                last_error = exc
                retryable = isinstance(exc, httpx.TransportError) or (
                    isinstance(exc, httpx.HTTPStatusError)
                    and (exc.response.status_code == 429 or exc.response.status_code >= 500)
                )
                if not retryable or attempt >= len(_RETRY_DELAYS):
                    break
                await asyncio.sleep(_retry_delay(exc, _RETRY_DELAYS[attempt]))
    raise PodcastSearchError(f"could not search podcasts: {last_error}") from last_error


def _retry_delay(error: Exception, fallback: float) -> float:
    if isinstance(error, httpx.HTTPStatusError):
        raw = error.response.headers.get("retry-after")
        try:
            return min(2.0, max(0.0, float(raw))) if raw is not None else fallback
        except ValueError:
            pass
    return fallback


def _matches(body: _AppleResponse) -> list[PodcastMatch]:
    matches: list[PodcastMatch] = []
    for result in body.results:
        if not result.feed_url or not _is_public_web_url(result.feed_url):
            continue
        matches.append(
            PodcastMatch(
                title=(result.title or "Untitled").strip() or "Untitled",
                feed_url=result.feed_url,
                publisher=result.publisher,
                episode_count=result.episode_count,
                artwork_url=result.artwork_600 or result.artwork_100,
                itunes_id=result.itunes_id,
                country=result.country,
                primary_genre=result.primary_genre,
                latest_release_date=result.latest_release_date,
            )
        )
    return matches


def _prepare(matches: list[PodcastMatch], query: str, strict: bool) -> list[PodcastMatch]:
    deduplicated: list[PodcastMatch] = []
    seen: set[str] = set()
    for match in matches:
        key = _feed_key(match.feed_url)
        if key in seen:
            continue
        seen.add(key)
        if not strict or _is_relevant(match, query):
            deduplicated.append(match)
    ranked = sorted(
        enumerate(deduplicated),
        key=lambda pair: _rank_key(pair[1], query, pair[0]),
    )
    return [match for _, match in ranked]


def matches_name(spoken: str, name: str) -> bool:
    """Does what she said identify this subscribed show?"""

    words = _identifying_words(spoken)
    haystack = _words(name)
    return bool(words) and all(_word_in(word, haystack) for word in words)


def meaningful_words(spoken: str) -> list[str]:
    """Words that identify a publication, in spoken order."""

    return [
        word
        for word in _normalise(spoken).split()
        if len(word) > 1 and word not in _FILLER and word not in _GENERIC_PUBLICATION_WORDS
    ]


def publication_name(spoken: str) -> str:
    """The identifying part of a spoken publication description.

    Dictation commonly renders brands and media as separate words — notably
    ``Substack`` as ``sub stack``. Publication types describe where to look,
    not what the publication is called, so keep them out of directory queries
    and candidate verification.
    """

    return " ".join(meaningful_words(spoken)) or spoken.strip()


def publication_display_name(spoken: str) -> str:
    """What to repeat aloud after removing a dictated platform suffix."""

    without_substack = re.sub(r"\bsub(?:[\s-]+)?stack\b", "", spoken, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", without_substack).strip() or spoken.strip()


def mentions_substack(spoken: str) -> bool:
    """Whether speech named Substack, including the split dictation form."""

    return "substack" in _normalise(spoken).split()


def loosely_identifies(spoken: str, haystack: str) -> bool:
    """Does speech identify text whose words may be glued in a URL?"""

    words = meaningful_words(spoken)
    if not words:
        return False
    squashed = _normalise(haystack).replace(" ", "")
    return all(word in squashed for word in words)


def _is_relevant(match: PodcastMatch, query: str) -> bool:
    spoken = _identifying_words(query)
    haystack = _words(f"{match.title} {match.publisher or ''}")
    return bool(spoken) and all(_word_in(word, haystack) for word in spoken)


def _rank_key(match: PodcastMatch, query: str, original_index: int) -> tuple[object, ...]:
    query_words = _identifying_words(query)
    title_words = _words(match.title)
    publisher_words = _words(match.publisher or "")
    title_identity = _identity(match.title)
    target = _identity(query)
    exact_title = title_identity == target
    title_contains_all = bool(query_words) and all(_word_in(word, title_words) for word in query_words)
    publisher_contains_all = bool(query_words) and all(_word_in(word, publisher_words) for word in query_words)
    phrase = bool(target) and target in title_identity
    edit_cost = sum(_best_edit_cost(word, title_words + publisher_words) for word in query_words)
    # False sorts before True, hence the negated booleans. Original order is
    # the final tie-breaker so Apple's relevance is retained where ours ties.
    return (
        not exact_title,
        not title_contains_all,
        not phrase,
        not publisher_contains_all,
        edit_cost,
        len(title_words),
        original_index,
    )


def _identity(value: str) -> str:
    return " ".join(word for word in _normalise(value).split() if word not in _FILLER)


def _identifying_words(value: str) -> list[str]:
    return [word for word in _normalise(value).split() if word not in _FILLER]


def _words(value: str) -> list[str]:
    return _normalise(value).split()


def _word_in(needle: str, haystack: list[str]) -> bool:
    return any(_within_one_edit(needle, word) for word in haystack)


def _best_edit_cost(needle: str, haystack: list[str]) -> int:
    if needle in haystack:
        return 0
    return 1 if any(_within_one_edit(needle, word) for word in haystack) else 3


def _within_one_edit(left: str, right: str) -> bool:
    """Damerau-Levenshtein distance at most one, without a matrix."""

    if left == right:
        return True
    # Short words are too collision-prone for fuzzy matching ("in"/"on").
    if min(len(left), len(right)) < 4 or abs(len(left) - len(right)) > 1:
        return False
    if len(left) == len(right):
        differences = [index for index, pair in enumerate(zip(left, right, strict=True)) if pair[0] != pair[1]]
        if len(differences) == 1:
            return True
        return (
            len(differences) == 2
            and differences[1] == differences[0] + 1
            and left[differences[0]] == right[differences[1]]
            and left[differences[1]] == right[differences[0]]
        )
    shorter, longer = (left, right) if len(left) < len(right) else (right, left)
    index = 0
    while index < len(shorter) and shorter[index] == longer[index]:
        index += 1
    return shorter[index:] == longer[index + 1 :]


def _feed_key(url: str) -> str:
    parsed = urlsplit(url)
    host = (parsed.hostname or "").casefold()
    port = parsed.port
    authority = host if port in {None, 80, 443} else f"{host}:{port}"
    path = parsed.path.rstrip("/") or "/"
    # RSS hosts commonly advertise the same document once as HTTP and once as
    # HTTPS. Treat those as aliases; playback already upgrades public assets
    # to HTTPS and the feed fetcher independently validates the final target.
    return urlunsplit(("https", authority, path, parsed.query, ""))


def _is_public_web_url(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        # Accessing ``port`` performs urllib's validation. Without it a value
        # such as ``https://example.com:not-a-port/feed`` gets through here
        # and raises later while the result list is being deduplicated.
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme in {"http", "https"}
        and bool(parsed.hostname)
        and parsed.username is None
        and parsed.password is None
        and port in {None, 80, 443}
    )


def _country_code(value: str | None) -> str | None:
    value = value.strip().lower() if value else None
    return value if value and len(value) == 2 and value.isalpha() else None


def _normalise(value: str) -> str:
    stripped = unicodedata.normalize("NFKD", value.casefold())
    words = re.sub(r"[^a-z0-9 ]", " ", stripped)
    words = re.sub(r"\s+", " ", words).strip()
    # Apple's dictation model hears the two ordinary English words clearly,
    # but often does not join the product name. Canonicalising it here lets
    # the existing generic-publication filter discard it without weakening
    # the safety check for unrelated names.
    return re.sub(r"\bsub stack\b", "substack", words)


# Words likely to be spoken but carrying no identifying information.
_FILLER = {"the", "a", "an", "podcast", "show", "to", "and", "of", "please"}

# Words that describe a publication rather than identifying it.
_GENERIC_PUBLICATION_WORDS = {"substack", "blog", "newsletter", "magazine", "site", "website"}
