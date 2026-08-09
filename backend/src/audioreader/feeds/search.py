"""Find a podcast's RSS feed from a spoken name.

Uses Apple's iTunes Search API: free, no key, and it covers essentially every
podcast, which is what lets her add a show without ever seeing a screen.
"""

import re
import unicodedata

import httpx
from pydantic import BaseModel

SEARCH_URL = "https://itunes.apple.com/search"


class PodcastSearchError(Exception):
    """The podcast directory could not be searched."""


class PodcastMatch(BaseModel):
    title: str
    feed_url: str
    publisher: str | None = None
    episode_count: int | None = None
    artwork_url: str | None = None


async def search_podcasts(query: str, limit: int = 5, strict: bool = True) -> list[PodcastMatch]:
    """Search the directory.

    strict=True is the voice path: every meaningful word she said must appear
    in the show's name or publisher, because a confidently wrong match acts on
    the wrong show with nothing on screen to catch it. Typed search in the app
    passes strict=False — the results are visible, so loose matches are useful
    rather than dangerous.
    """
    params = {"term": query, "entity": "podcast", "limit": str(limit)}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(SEARCH_URL, params=params)
            response.raise_for_status()
            body = response.json()
    except httpx.HTTPError as exc:
        raise PodcastSearchError(f"could not search podcasts: {exc}") from exc
    except ValueError as exc:
        raise PodcastSearchError("podcast directory returned invalid JSON") from exc

    matches = [
        PodcastMatch(
            title=result.get("collectionName") or "Untitled",
            feed_url=result["feedUrl"],
            publisher=result.get("artistName"),
            episode_count=result.get("trackCount"),
            artwork_url=result.get("artworkUrl600") or result.get("artworkUrl100"),
        )
        # A podcast with no feed URL cannot be subscribed to, however well it
        # matches the spoken name.
        for result in body.get("results", [])
        if result.get("feedUrl")
    ]
    if strict:
        matches = [m for m in matches if _is_relevant(m, query)]
    return _best_first(matches, query)


def _best_first(matches: list[PodcastMatch], query: str) -> list[PodcastMatch]:
    """Promote an exact name match.

    Search relevance often puts a spin-off ("... : Club") or a discussion
    podcast above the show she actually asked for.
    """
    target = _normalise(query)
    return sorted(matches, key=lambda match: _normalise(match.title) != target)


def matches_name(spoken: str, name: str) -> bool:
    """Does what she said identify this show?

    Every meaningful word she said must appear in the name, which keeps
    partial names working ("politics" -> "The Rest Is Politics") without
    matching unrelated shows.
    """
    words = _tokens(spoken) - _FILLER
    return bool(words) and words <= _tokens(name)


def meaningful_words(spoken: str) -> list[str]:
    """The words that identify a publication, in spoken order.

    Filler, genre words ("substack", "blog") and possessive fragments ("s"
    from "Halligan's") are dropped: they say what kind of thing it is, never
    which one.
    """
    return [
        word
        for word in _normalise(spoken).split()
        if len(word) > 1 and word not in _FILLER and word not in _GENERIC_PUBLICATION_WORDS
    ]


def loosely_identifies(spoken: str, haystack: str) -> bool:
    """Does what she said identify this publication?

    Looser than matches_name, for web discovery where the identifying text
    includes URLs: words there are glued together ("liam halligan" appears as
    "liamhalligan.substack.com"), so each meaningful spoken word need only
    appear as a substring of the squashed haystack.
    """
    words = meaningful_words(spoken)
    if not words:
        return False
    squashed = _normalise(haystack).replace(" ", "")
    return all(word in squashed for word in words)


def _is_relevant(match: PodcastMatch, query: str) -> bool:
    """Guard against confidently wrong matches.

    The directory nearly always returns *something*, so an unfiltered top
    result means a misheard name quietly subscribes her to a stranger's
    podcast. Requiring every meaningful word she said to appear in the show's
    name or publisher keeps partial names working ("joe rogan") while
    rejecting noise.
    """
    spoken = _tokens(query) - _FILLER
    if not spoken:
        return False
    haystack = _tokens(f"{match.title} {match.publisher or ''}")
    return spoken <= haystack


def _tokens(value: str) -> set[str]:
    return set(_normalise(value).split())


def _normalise(value: str) -> str:
    stripped = unicodedata.normalize("NFKD", value.casefold())
    return re.sub(r"[^a-z0-9 ]", " ", stripped).strip()


#: Words she is likely to say that carry no identifying information.
_FILLER = {"the", "a", "an", "podcast", "show", "to", "and", "of", "please"}

#: Words that describe what kind of publication it is, not which one.
_GENERIC_PUBLICATION_WORDS = {"substack", "blog", "newsletter", "magazine", "site", "website"}
