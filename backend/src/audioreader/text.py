"""Turn feed HTML into plain text.

Two audiences, two functions: `summarise` trims descriptions down to something
cheap to feed an LLM, and `for_speech` prepares text to be read aloud.
"""

import re
from html import unescape
from html.parser import HTMLParser

_WHITESPACE = re.compile(r"\s+")
_URL = re.compile(r"https?://\S+")
# Tags whose text content is markup, not prose, and must never be read out.
_NON_PROSE_TAGS = {"script", "style"}


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._suppress_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _NON_PROSE_TAGS:
            self._suppress_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in _NON_PROSE_TAGS and self._suppress_depth > 0:
            self._suppress_depth -= 1

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
