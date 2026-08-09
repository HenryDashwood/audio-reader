"""Speech-ready text for episodes that are written articles, not audio.

The feed's own <content:encoded> is preferred: Substack and most personal
blogs ship the full article there. Feeds that only carry a summary fall back
to fetching the article page and extracting its body with trafilatura. The
result is cached on the episode row so replaying never refetches.
"""

import logging

import httpx
import trafilatura
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import Episode
from audioreader.text import article_text, for_speech

logger = logging.getLogger(__name__)

#: Feed content shorter than this is treated as a teaser, not the article:
#: summary-only feeds typically ship a sentence or two, full-content feeds
#: thousands of characters.
FULL_TEXT_THRESHOLD = 600


async def text_for(session: AsyncSession, episode: Episode) -> str | None:
    """The episode's article as speech-ready paragraphs, or None.

    Caches on first success. Failures are not cached, so a page that was
    temporarily down is retried on the next request.
    """
    if episode.article_text:
        return episode.article_text

    text = article_text(episode.content_html)
    if len(text) < FULL_TEXT_THRESHOLD and episode.link:
        fetched = await _extract_from_page(episode.link)
        # The page body wins only when it is actually richer than the feed's.
        if fetched and len(fetched) > len(text):
            text = fetched
    if not text:
        text = article_text(episode.description)
    if not text:
        return None

    episode.article_text = text
    await session.commit()
    return text


async def _extract_from_page(url: str) -> str | None:
    try:
        async with httpx.AsyncClient(
            timeout=20, follow_redirects=True, headers={"User-Agent": "audioreader/0.1"}
        ) as client:
            response = await client.get(url)
            response.raise_for_status()
            html = response.text
    except httpx.HTTPError as exc:
        logger.warning("could not fetch article page %s: %s", url, exc)
        return None

    # favor_recall keeps whole paragraphs at the cost of the odd caption —
    # for listening, a missing paragraph is worse than a stray one.
    extracted = trafilatura.extract(html, favor_recall=True, include_comments=False)
    if not extracted:
        return None
    paragraphs = [cleaned for line in extracted.splitlines() if (cleaned := for_speech(line))]
    return "\n\n".join(paragraphs)
