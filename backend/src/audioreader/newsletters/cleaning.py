"""An email's markup, reduced to the issue somebody wrote.

Newsletter HTML is built for mail clients: a grid of nested layout tables, a
hidden preview line for the inbox, a tracking pixel, and a footer of
unsubscribe links, share buttons and postal addresses. Read aloud, all of
that comes out as prose — "View this email in your browser. Share. Like.
731 Lexington Avenue" — before and after the writing itself. This takes it
out.

Deliberately conservative: a paragraph wrongly removed is gone from the reading
for good, while a stray line of boilerplate is only a nuisance. The rules that
can fire anywhere each remove something small and unmistakable; the looser
ones only ever eat backwards from the end of the message.
"""

import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass

from lxml import html as lxml_html

logger = logging.getLogger(__name__)

#: Text that only ever appears in the wrapper around an issue, never in it.
#: Applied to any block short enough to be a footer line rather than a
#: paragraph of writing.
_BOILERPLATE = re.compile(
    r"unsubscribe"
    r"|manage (?:your )?(?:subscription|preferences|email)"
    r"|update (?:your )?(?:preferences|profile|subscription)"
    r"|email preferences"
    r"|view (?:this (?:email|message|newsletter)|it|this) (?:online|in (?:your|a) (?:web )?browser)"
    r"|view in (?:your )?browser"
    r"|read (?:this )?(?:online|in browser)"
    r"|open in (?:your )?browser"
    r"|why (?:did i|am i|you[’']?re) (?:get|getting|receiv)"
    r"|you(?:'re| are) receiving this"
    r"|you (?:received|got) this (?:message|email|newsletter)"
    r"|you(?:'re| are) (?:currently )?(?:a |getting the )?(?:free|paid|premium)"
    r"|(?:was|were) sent to"
    r"|forward(?:ed)? (?:this|to a friend)"
    r"|add us to your address book"
    r"|like getting this newsletter"
    r"|(?:want to )?sponsor this newsletter"
    r"|copy and paste this link"
    r"|join the discussion"
    r"|before it[’']?s here,? it[’']?s on the bloomberg terminal",
    re.IGNORECASE,
)

#: What a mail app writes above a message forwarded by hand, and the header
#: lines it copies under that. Chrome of the forwarding, not of the issue.
_FORWARDING_CHROME = re.compile(
    r"^(?:-{2,}\s*Forwarded message\s*-{2,}|Begin forwarded message:|-{2,}\s*Original Message\s*-{2,})"
    r"|^(?:From|Date|Sent|Subject|To|Cc|Reply-To):\s",
    re.IGNORECASE,
)

#: Whole blocks that are a button or a nav label rather than a sentence.
_LABEL = re.compile(
    r"share|like|comment|restack|reply|forward|tweet|read in app|read online|view online"
    r"|follow us|get the newsletter|subscribe(?: now| or upgrade)?|upgrade(?: to (?:paid|premium))?"
    r"|leave a comment|unsubscribe|manage preferences"
    r"|facebook|twitter|x|linkedin|instagram|youtube|threads|bluesky|mastodon|tiktok|website",
    re.IGNORECASE,
)

#: Lines that close a message. Only removed as a run at the very end, because
#: any one of them could also be a caption or a footnote in the middle.
_CLOSING = re.compile(
    # Case-insensitive for the phrases; the postal patterns below lean on
    # capitalised state codes, so the flag is scoped rather than global.
    r"(?i:copyright|©|\(c\)\s*(?:19|20)\d\d|all rights reserved|powered by|sent (?:with|via|using))"
    r"|\b\d{5}(?:-\d{4})?\b.*(?:,\s*[A-Z]{2}\b|\bUnited States\b|\bUSA\b)"  # US postal address
    r"|(?:,\s*[A-Z]{2}\b|\bUnited States\b|\bUSA\b).*\b\d{5}(?:-\d{4})?\b"
    r"|\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b"  # UK postcode
    r"|\bUnited Kingdom\b",
)

#: A link back to the issue's page on the web. Kept as the item's link, so the
#: reader has somewhere to go and the app can show the hosted version.
_BROWSER_LINK = re.compile(
    r"view (?:this (?:email|message|newsletter|post)|it|this)? ?(?:online|in (?:your |a )?(?:web )?browser|on the web)"
    r"|view in (?:your )?browser"
    r"|read (?:this )?(?:online|in browser|on the web)"
    r"|open in (?:your )?browser"
    r"|view this post on the web",
    re.IGNORECASE,
)

#: Inline styles that hide an element in a mail client: the inbox preview
#: line, and layout tricks for Outlook.
_HIDDEN_STYLE = re.compile(
    r"display\s*:\s*none"
    r"|visibility\s*:\s*hidden"
    r"|mso-hide\s*:\s*all"
    r"|max-height\s*:\s*0(?:px)?\s*(?:;|!|$)"
    r"|font-size\s*:\s*0(?:px|pt|em)?\s*(?:;|!|$)"
    r"|opacity\s*:\s*0\s*(?:;|!|$)",
    re.IGNORECASE,
)

_TRACKING_PIXEL_SRC = re.compile(r"/track/open|/open\.gif|/o\.gif|/open\?|/wf/open", re.IGNORECASE)

#: Preview lines are padded with invisible characters so the inbox shows
#: nothing after them. None of it is text.
_INVISIBLE = re.compile(r"[͏​-‏  ﻿­⠀]")

#: The largest block that can be removed for containing boilerplate. Big
#: enough for a footer paragraph, far too small for anything the writer wrote.
_MAX_BOILERPLATE_CHARS = 600
_MAX_CLOSING_CHARS = 300
_MIN_PREVIEW_ALNUM = 12

#: Block-level containers only. Spans are inline, and treating them as
#: blocks would make half a sentence a "leaf" of its own.
_BLOCKS = {
    "p", "div", "td", "th", "li", "tr", "table", "tbody", "section", "footer", "center",
    "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "figcaption", "pre",
}  # fmt: skip
_TABLE_TAGS = {"table", "thead", "tbody", "tfoot", "tr", "td", "th", "center"}
_DROPPED_TAGS = {"script", "style", "head", "title", "meta", "link", "noscript", "iframe", "object", "embed"}
_WHITESPACE = re.compile(r"\s+")


@dataclass(frozen=True)
class CleanedIssue:
    html: str
    #: Where the same issue lives on the web, when the email says.
    browser_url: str | None
    #: The one-line summary written for the inbox, when the email carries one.
    preview_text: str | None


def clean_newsletter_html(html: str, *, subject: str | None = None) -> CleanedIssue:
    """The issue's own markup, with the email chrome around it removed.

    Tables are flattened to divs on the way out. In an email they are layout,
    not data, and left as tables the app would read a row's cells run
    together as one word. The result is still untrusted markup; it goes
    through the same allowlist as any feed's before it is shown.
    """
    if not html or not html.strip():
        return CleanedIssue(html="", browser_url=None, preview_text=None)
    try:
        document = lxml_html.document_fromstring(html)
        body = document.body
    except Exception as exc:  # noqa: BLE001 - lxml's parser errors are a long, version-specific list
        logger.warning("newsletter HTML could not be parsed; keeping it as it is: %s", exc)
        return CleanedIssue(html=html, browser_url=None, preview_text=None)

    _drop(element for element in body.iter() if _is_tag(element) and element.tag in _DROPPED_TAGS)
    preview_text = _preview_text(body)
    browser_url = _browser_url(body, subject)
    _drop(element for element in body.iter() if _is_tag(element) and _is_hidden(element))
    _drop(element for element in body.iter("img") if _is_tracking_pixel(element))
    _drop(_boilerplate_blocks(body))
    _drop_repeated_subject(body, subject)
    _drop_closing_run(body)
    for element in body.iter():
        if _is_tag(element) and element.tag in _TABLE_TAGS:
            element.tag = "div"
            for attribute in ("width", "height", "colspan", "rowspan", "cellpadding", "cellspacing", "border"):
                element.attrib.pop(attribute, None)

    parts = [body.text or ""]
    parts.extend(lxml_html.tostring(child, encoding="unicode") for child in body)
    return CleanedIssue(html="".join(parts).strip(), browser_url=browser_url, preview_text=preview_text)


def _is_tag(element: lxml_html.HtmlElement) -> bool:
    # Comments and processing instructions have a callable in place of a tag.
    return isinstance(element.tag, str)


def _text(element: lxml_html.HtmlElement) -> str:
    return _WHITESPACE.sub(" ", _INVISIBLE.sub("", element.text_content())).strip()


def _drop(elements: Iterable[lxml_html.HtmlElement]) -> None:
    # Materialised first: removing while iterating the same tree skips nodes.
    for element in list(elements):
        if element.getparent() is None:
            continue
        # drop_tree keeps the tail text, so a sentence that continued after a
        # removed inline element is not cut short.
        element.drop_tree()


def _is_hidden(element: lxml_html.HtmlElement) -> bool:
    style = element.get("style") or ""
    if _HIDDEN_STYLE.search(style):
        return True
    if element.get("hidden") is not None:
        return True
    names = f"{element.get('class') or ''} {element.get('id') or ''}".lower()
    return "preheader" in names or "preview-text" in names


def _is_tracking_pixel(element: lxml_html.HtmlElement) -> bool:
    width = (element.get("width") or "").strip().rstrip("px")
    height = (element.get("height") or "").strip().rstrip("px")
    if width in {"0", "1"} or height in {"0", "1"}:
        return True
    style = (element.get("style") or "").replace(" ", "")
    if re.search(r"(?:^|;)(?:width|height):[01]px", style):
        return True
    return bool(_TRACKING_PIXEL_SRC.search(element.get("src") or ""))


def _preview_text(body: lxml_html.HtmlElement) -> str | None:
    """The inbox preview line: hidden from the reader, written as a summary."""
    for element in body.iter():
        if not _is_tag(element) or not _is_hidden(element):
            continue
        text = _text(element)
        if sum(character.isalnum() for character in text) >= _MIN_PREVIEW_ALNUM:
            return text[:400]
    return None


def _browser_url(body: lxml_html.HtmlElement, subject: str | None) -> str | None:
    """A "view in browser" link, or failing that the title linking to itself,
    which is how Substack and its like point at the post's page."""
    titled = _normalised(subject) if subject else None
    by_title = None
    for anchor in body.iter("a"):
        href = (anchor.get("href") or "").strip()
        if not href.lower().startswith(("http://", "https://")):
            continue
        label = _text(anchor)
        if len(label) <= 80 and _BROWSER_LINK.search(label):
            return href[:4_096]
        if by_title is None and titled and _normalised(label) == titled:
            by_title = href[:4_096]
    return by_title


def _normalised(text: str) -> str:
    return _WHITESPACE.sub(" ", text).strip().casefold()


def _is_boilerplate(element: lxml_html.HtmlElement) -> bool:
    text = _text(element)
    if not text:
        return False
    if _LABEL.fullmatch(text):
        return True
    if len(text) <= _MAX_BOILERPLATE_CHARS and _FORWARDING_CHROME.match(text):
        return True
    if not any(character.isalnum() for character in text) and element.find(".//img") is None:
        # A lone "|" between two footer links.
        return True
    return len(text) <= _MAX_BOILERPLATE_CHARS and bool(_BOILERPLATE.search(text))


def _boilerplate_blocks(body: lxml_html.HtmlElement) -> list[lxml_html.HtmlElement]:
    """The smallest blocks whose text is only email chrome.

    A footer table matches as a whole, but so do its cells, and taking the
    cells leaves whatever else was in the table alone.
    """
    matched = [
        element for element in body.iter() if _is_tag(element) and element.tag in _BLOCKS and _is_boilerplate(element)
    ]
    return [
        element
        for element in matched
        if not any(other is not element and _is_ancestor(element, other) for other in matched)
    ]


def _is_ancestor(ancestor: lxml_html.HtmlElement, element: lxml_html.HtmlElement) -> bool:
    parent = element.getparent()
    while parent is not None:
        if parent is ancestor:
            return True
        parent = parent.getparent()
    return False


def _leaf_blocks(body: lxml_html.HtmlElement) -> list[lxml_html.HtmlElement]:
    """Blocks with text of their own and no block with text inside them, in
    reading order — the units the reader will speak one at a time."""
    leaves = []
    for element in body.iter():
        if not _is_tag(element) or element.tag not in _BLOCKS or not _text(element):
            continue
        if any(_is_tag(child) and child.tag in _BLOCKS and _text(child) for child in element.iterdescendants()):
            continue
        leaves.append(element)
    return leaves


def _drop_repeated_subject(body: lxml_html.HtmlElement, subject: str | None) -> None:
    """Substack and Beehiiv open the body with the title. It is the item's
    title already, and would be read twice."""
    if not subject:
        return
    leaves = _leaf_blocks(body)
    if leaves and _normalised(_text(leaves[0])) == _normalised(subject):
        _drop([leaves[0]])


def _drop_closing_run(body: lxml_html.HtmlElement) -> None:
    """Eat the copyright line, postal address and platform credit off the end.

    Backwards from the last block, stopping at the first one that reads like
    writing. None of these patterns is safe to remove from the middle of a
    message — a footnote can mention a year, a caption can carry a © — so
    position is the evidence.
    """
    trailing = []
    for element in reversed(_leaf_blocks(body)):
        text = _text(element)
        if len(text) <= _MAX_CLOSING_CHARS and (_CLOSING.search(text) or _LABEL.fullmatch(text)):
            trailing.append(element)
            continue
        break
    _drop(trailing)
