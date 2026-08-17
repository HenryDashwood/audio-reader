"""Article content for episodes that are written pieces, not audio.

Two shapes of the same article come out of here: speech-ready paragraphs for
the player, and sanitised HTML for the reader — headings, emphasis, links and
images, none of which survive the trip to speech. They are derived from one
extraction and cached together, so opening an article and listening to it cost
one fetch between them rather than one each.

The feed's own <content:encoded> is preferred: Substack and most personal
blogs ship the full article there, with its markup intact. Feeds that only
carry a summary fall back to fetching the article page and extracting its body
with trafilatura.
"""

import logging

import httpx
import nh3
import trafilatura
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.latex import with_mathml
from audioreader.models import Episode
from audioreader.text import article_text

logger = logging.getLogger(__name__)

#: MathML's presentation elements, on top of nh3's own allowlist, so a formula
#: survives the trip to the reader. `semantics`/`annotation` are deliberately
#: absent: an annotation carries the original TeX, which browsers hide and a
#: screen reader would happily read out.
_MATHML_TAGS = {
    "math", "merror", "mfrac", "mi", "mmultiscripts", "mn", "mo", "mover", "mpadded",
    "mphantom", "mprescripts", "mroot", "mrow", "ms", "mspace", "msqrt", "mstyle",
    "msub", "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder", "munderover",
    "none",
}  # fmt: skip

_ALLOWED_TAGS = nh3.ALLOWED_TAGS | _MATHML_TAGS

#: Operators carry most of MathML's fine typesetting: which brackets grow to
#: the height of what they hold, how much air sits either side of a sign.
_OPERATOR_ATTRIBUTES = {
    "accent", "fence", "largeop", "lspace", "maxsize", "minsize",
    "movablelimits", "rspace", "separator", "stretchy", "symmetric",
}  # fmt: skip

#: Enough of MathML's attributes for a formula to keep its shape — how a table
#: of equations lines up, which fences stretch, where the spaces are.
_ALLOWED_ATTRIBUTES = {
    **nh3.ALLOWED_ATTRIBUTES,
    # The reader gives a display formula a box of its own to scroll in.
    "span": {"class"},
    "math": {"display", "xmlns"},
    "mfrac": {"linethickness"},
    "mi": {"mathvariant"},
    "mn": {"mathvariant"},
    "mo": _OPERATOR_ATTRIBUTES,
    "mover": {"accent"},
    "mpadded": {"depth", "height", "lspace", "voffset", "width"},
    "ms": {"lquote", "rquote"},
    "mspace": {"depth", "height", "width"},
    "mstyle": {"displaystyle", "mathvariant", "scriptlevel"},
    "mtable": {"columnalign", "columnspacing", "displaystyle", "frame", "rowalign", "rowspacing"},
    "mtd": {"columnalign", "columnspan", "rowalign", "rowspan"},
    "mtext": {"mathvariant"},
    "mtr": {"columnalign", "rowalign"},
    "munder": {"accentunder"},
    "munderover": {"accent", "accentunder"},
}

#: Tags stripped along with everything inside them, rather than unwrapped:
#: the text of a script is not prose, and neither is a TeX annotation.
_STRIPPED_WHOLE = {"script", "style", "annotation", "annotation-xml"}

#: Feed content shorter than this is treated as a teaser, not the article:
#: summary-only feeds typically ship a sentence or two, full-content feeds
#: thousands of characters. Measured on the text, not the markup, so a
#: paragraph wrapped in a div-per-word template is still a teaser.
FULL_TEXT_THRESHOLD = 600


async def content_for(session: AsyncSession, episode: Episode) -> tuple[str, str | None]:
    """The article as (speech-ready text, HTML ready to show), or ("", None).

    Caches on first success. Failures are not cached, so a page that was
    temporarily down is retried on the next request.
    """
    if episode.article_text and episode.article_html:
        return episode.article_text, rendered(episode.article_html)

    html = sanitised(episode.content_html)
    if len(article_text(html)) < FULL_TEXT_THRESHOLD and episode.link:
        fetched = await _extract_from_page(episode.link)
        # The page body wins only when it is actually richer than the feed's.
        if fetched and len(article_text(fetched)) > len(article_text(html)):
            html = fetched
    if not article_text(html):
        html = sanitised(episode.description)

    # An article already read aloud keeps the exact text it was read from.
    # Re-deriving it could shift the player's estimated timeline under a
    # position she saved against the old one, and land her in the wrong place.
    text = episode.article_text or article_text(html)
    if not text:
        return "", None

    episode.article_text = text
    episode.article_html = html or None
    await session.commit()
    return text, rendered(episode.article_html)


async def text_for(session: AsyncSession, episode: Episode) -> str | None:
    """Just the spoken text, for callers that never show anything."""
    text, _ = await content_for(session, episode)
    return text or None


def sanitised(html: str | None) -> str:
    """Feed or page markup reduced to what is safe to render.

    An allowlist, not a blocklist: scripts, embeds, inline event handlers,
    `javascript:` URLs and inline styles all go, and what survives is
    structure, prose and maths. The app renders this with JavaScript switched
    off as well — two locks on a door that opens onto whatever a blog happens
    to serve.
    """
    if not html:
        return ""
    return nh3.clean(
        html,
        tags=_ALLOWED_TAGS,
        attributes=_ALLOWED_ATTRIBUTES,
        clean_content_tags=_STRIPPED_WHOLE,
    ).strip()


def rendered(html: str | None) -> str | None:
    """The stored article as the reader should see it, with its LaTeX set as
    MathML.

    Done on the way out rather than on the way in, so that a formula the
    converter learns to handle next month also fixes the articles already
    cached — and so the spoken text, which is derived once and then frozen
    against the position she has saved, is left exactly as it was.

    The conversion's own output goes back through the allowlist: it is
    assembled from whatever a blog wrote between two dollar signs, and the
    converter passes markup in that text straight through.
    """
    if not html:
        return None
    maths = with_mathml(html)
    # No formulas: the stored markup has already been through the allowlist.
    return html if maths == html else sanitised(maths) or None


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
    # for listening, a missing paragraph is worse than a stray one. The rest
    # asks for everything the reader can show: an article stripped to bare
    # <p> would lose its pictures and every link in it.
    extracted = trafilatura.extract(
        html,
        output_format="html",
        favor_recall=True,
        include_comments=False,
        include_formatting=True,
        include_images=True,
        include_links=True,
        include_tables=True,
    )
    if not extracted:
        return None
    return sanitised(extracted)
