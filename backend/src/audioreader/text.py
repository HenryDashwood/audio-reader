"""Turn feed HTML into plain text.

Three audiences, three functions: `summarise` trims descriptions down to
something cheap to feed an LLM, `for_speech` prepares a sentence to be read
aloud, and `article_text` turns a full article's HTML into paragraphs a
speech synthesiser can read one at a time.
"""

import re
from html import unescape
from html.parser import HTMLParser

_WHITESPACE = re.compile(r"\s+")
_URL = re.compile(r"https?://\S+")
# Tags whose text content is markup, not prose, and must never be read out.
_NON_PROSE_TAGS = {"script", "style"}
# Tags that end one run of prose and start another. Without these boundaries a
# heading would be read glued onto the first sentence of its section.
_BLOCK_TAGS = {
    "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
    "blockquote", "figure", "figcaption", "section", "article", "header",
    "footer", "aside", "table", "tr", "pre", "hr",
}  # fmt: skip


class _TextExtractor(HTMLParser):
    def __init__(self, block_breaks: bool = False) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._suppress_depth = 0
        self._block_breaks = block_breaks

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _NON_PROSE_TAGS:
            self._suppress_depth += 1
        elif self._block_breaks and tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in _NON_PROSE_TAGS and self._suppress_depth > 0:
            self._suppress_depth -= 1
        elif self._block_breaks and tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._suppress_depth == 0:
            self.parts.append(data)


def strip_html(value: str | None) -> str:
    if not value:
        return ""
    extractor = _TextExtractor()
    extractor.feed(value)
    extractor.close()
    return _WHITESPACE.sub(" ", unescape("".join(extractor.parts))).strip()


def summarise(value: str | None, limit: int = 400) -> str:
    """Plain-text description, truncated at a word boundary."""
    text = strip_html(value)
    if len(text) <= limit:
        return text
    # Leave room for the ellipsis, then cut back to the last whole word —
    # unless the cut already landed on a word boundary.
    clipped = text[: limit - 1]
    if not text[limit - 1].isspace():
        clipped = clipped.rsplit(" ", 1)[0]
    return f"{clipped.rstrip()}…"


def for_speech(value: str | None) -> str:
    """Plain text safe to hand to a speech synthesiser.

    URLs are unlistenable read character by character, so they are dropped
    rather than spoken.
    """
    return _WHITESPACE.sub(" ", _URL.sub("", strip_html(value))).strip()


def article_paragraphs(value: str | None) -> list[str]:
    """An article's HTML as clean spoken paragraphs, in order.

    Block boundaries become paragraph breaks so the synthesiser pauses between
    a heading and its section, and so the app can skip by paragraph. Link text
    is kept ("read the paper" stays); raw URLs are dropped as unspeakable.
    """
    if not value:
        return []
    extractor = _TextExtractor(block_breaks=True)
    extractor.feed(value)
    extractor.close()
    raw = unescape("".join(extractor.parts))
    paragraphs = []
    for chunk in raw.split("\n"):
        text = _WHITESPACE.sub(" ", _URL.sub("", chunk)).strip()
        if text:
            paragraphs.append(text)
    return paragraphs


def article_text(value: str | None) -> str:
    """The whole article as speech-ready text, paragraphs separated by blank
    lines — the shape the app's reader chunks on."""
    return "\n\n".join(article_paragraphs(value))
