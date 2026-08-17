"""Maths written as LaTeX, set as MathML the reader can draw.

Blogs that write formulas ship them as TeX between dollar signs and leave the
drawing to a script in the page. A feed reader never runs that script, so the
article arrives with `$$ \\frac{QK^T}{\\sqrt{d_k}} $$` sitting in the middle of
a paragraph, which is not a formula — it is the recipe for one.

MathML rather than a picture of a formula or a JavaScript renderer in the web
view: WebKit draws it natively, in the article's own font at the article's own
text size, so it survives being cached for offline reading and — the reason
that matters most here — VoiceOver reads it as maths rather than spelling out
TeX or announcing an image.

What counts as maths is a guess, and the guess is deliberately timid. `$5 and
$10` is a pair of prices, not an equation, so an opening `$` must be followed
immediately by something other than a space and the closing one preceded by
the same; dollars inside code samples are left alone entirely. A formula that
is missed reads exactly as badly as it does today, while a sentence wrongly
taken for maths is a sentence nobody can read at all.
"""

import logging
import re
from html import unescape

import latex2mathml.converter

logger = logging.getLogger(__name__)

#: Tags whose text is not prose and whose dollar signs are therefore not
#: maths — a shell snippet is full of `$PATH`, and markup already set as
#: MathML has been through this once.
_OPAQUE = {"pre", "code", "math", "script", "style"}

_TAG = re.compile(r"(<[^>]*>)")
_TAG_NAME = re.compile(r"</?\s*([a-zA-Z0-9-]+)")

#: The four ways an article writes a formula. Display forms come first so that
#: `$$` is never read as an empty `$...$`.
_MATHS = re.compile(
    r"""
      \$\$(?P<display>[^$]+?)\$\$              # $$ ... $$
    | \\\[(?P<bracket>.+?)\\\]                 # \[ ... \]
    | \\\((?P<paren>.+?)\\\)                   # \( ... \)
    | (?<![\\$])\$(?P<inline>[^\s$][^$\n]*?)(?<!\s)\$(?!\$)
    """,
    re.VERBOSE | re.DOTALL,
)


def with_mathml(html: str) -> str:
    """Article markup with its LaTeX replaced by MathML.

    Formulas the converter cannot parse are left as they were: a stray `$$`
    in the text is the state of things today, and better than half an
    equation.
    """
    if not ("$" in html or "\\(" in html or "\\[" in html):
        return html

    parts = _TAG.split(html)
    opaque = 0
    for index, part in enumerate(parts):
        # Odd indices are the tags themselves, kept exactly as they came.
        if index % 2:
            if (name := _TAG_NAME.match(part)) and name.group(1).lower() in _OPAQUE:
                opaque = max(0, opaque - 1) if part.startswith("</") else opaque + 1
        elif not opaque and part:
            parts[index] = _MATHS.sub(_replaced, part)
    return "".join(parts)


#: A row break in an environment, with one of its two backslashes eaten. Feed
#: generators that run the article through a Markdown escape on the way out do
#: this, and the site's own page then renders seven lines where its feed
#: renders one very long one. A lone backslash before a space is a control
#: space in real TeX, which nobody writes at the end of a row of an equation,
#: so reading it as the row break it almost certainly was is the safer guess.
_LOST_ROW_BREAK = re.compile(r"(?<!\\)\\(?=\s)")


def _replaced(match: re.Match[str]) -> str:
    display = match["display"] or match["bracket"]
    # Text nodes arrive escaped, and TeX uses both `&` and `<` for its own
    # purposes — `&` aligns the rows of an `align*` block.
    source = unescape(display or match["paren"] or match["inline"])
    if "\\begin{" in source:
        source = _LOST_ROW_BREAK.sub(r"\\\\", source)
    mathml = _mathml(source, block=display is not None)
    if mathml is None:
        return match[0]
    if display is None:
        return mathml
    # An equation on its own line can be wider than a phone, and WebKit will
    # not scroll a `<math>` element itself however it is styled — it widens
    # the whole article instead, so every paragraph in it then slides sideways
    # under the thumb. A span because this sits inside the article's own
    # paragraph, where a div would end it early.
    return f'<span class="formula">{mathml}</span>'


def _mathml(source: str, block: bool) -> str | None:
    try:
        return latex2mathml.converter.convert(source, display="block" if block else "inline")
    # The converter raises exceptions of its own for TeX it does not know, and
    # index errors for some of what is simply malformed. Neither is worth
    # failing a whole article over, and what a blog puts between two dollar
    # signs is not ours to predict.
    except Exception as exc:
        logger.info("could not set %r as MathML: %s", source[:120], exc)
        return None
