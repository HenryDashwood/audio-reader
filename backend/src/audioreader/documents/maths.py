"""Datalab's LaTeX-bearing math tags are not yet presentation MathML.

Keep this adapter PDF-specific: changing existing article narration would change
its saved word offsets. The private raw provider result retains the original TeX.
"""

import re
from copy import deepcopy

from latex2mathml.converter import convert
from lxml import html as lhtml

FALLBACK_CLASS = "pdf-equation-fallback"
SPEECH_FALLBACK = "Equation. See the equation in the reader."
MAX_SOURCE = 8192
_ENVIRONMENT = re.compile(r"\\(begin|end)\{([^{}]+)\}")
# latex2mathml understands align* but silently flattens the KaTeX aligned alias.
_ENV_ALIASES = {"aligned": "align*", "gathered": "matrix"}
_ENVIRONMENTS = {
    "align",
    "align*",
    "split",
    "matrix",
    "pmatrix",
    "bmatrix",
    "Bmatrix",
    "vmatrix",
    "Vmatrix",
    "smallmatrix",
    "array",
    "cases",
}
_MATHML = {
    "merror",
    "mfrac",
    "mi",
    "mmultiscripts",
    "mn",
    "mo",
    "mover",
    "mpadded",
    "mphantom",
    "mprescripts",
    "mroot",
    "mrow",
    "ms",
    "mspace",
    "msqrt",
    "mstyle",
    "msub",
    "msubsup",
    "msup",
    "mtable",
    "mtd",
    "mtext",
    "mtr",
    "munder",
    "munderover",
    "semantics",
}
_OPERATORS = {
    "+": "plus",
    "−": "minus",
    "-": "minus",
    "=": "equals",
    "≠": "not equal to",
    "<": "less than",
    ">": "greater than",
    "≤": "less than or equal to",
    "≥": "greater than or equal to",
    "×": "times",
    "·": "times",
    "/": "divided by",
    "÷": "divided by",
    "±": "plus or minus",
    "∞": "infinity",
    "(": "open parenthesis",
    ")": "close parenthesis",
    "[": "open bracket",
    "]": "close bracket",
    ",": "comma",
    ";": "semicolon",
    ":": "colon",
    "!": "factorial",
}
_GREEK = dict(
    zip(
        "αβγδεζηθικλμνξπρστυφχψω",
        (
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi pi rho sigma tau "
            "upsilon phi chi psi omega"
        ).split(),
        strict=True,
    )
)


def convert_wrappers(page: lhtml.HtmlElement) -> None:
    for node in list(page.xpath(".//math[not(ancestor::math)]")):
        source = "".join(node.itertext()).strip()
        display = node.get("display") == "block"
        # Real presentation MathML is already ready for the existing sanitiser.
        if len(node) and all(child.tag in _MATHML for child in node):
            replacement = deepcopy(node)
        else:
            replacement = _converted(source, display) if not len(node) else None
        if replacement is None:
            replacement = lhtml.Element("span", {"class": FALLBACK_CLASS})
            replacement.text = "Equation (LaTeX): "
            code = lhtml.Element("code")
            replacement.append(code)
            code.text = source or "Unavailable; check the original PDF."
        if display:
            wrapper = lhtml.Element("span", {"class": "formula"})
            wrapper.append(replacement)
            replacement = wrapper
        replacement.tail = node.tail
        node.getparent().replace(node, replacement)


def _converted(source: str, display: bool) -> lhtml.HtmlElement | None:
    if not source or len(source) > MAX_SOURCE:
        return None
    for opening, closing in [("$$", "$$"), (r"\[", r"\]"), (r"\(", r"\)"), ("$", "$")]:
        if source.startswith(opening) and source.endswith(closing):
            source = source[len(opening) : -len(closing)].strip()
            break
    # Reject unbalanced/deep groups before entering the recursive converter.
    depth = 0
    for char in re.sub(r"\\[{}]", "", source):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        if depth < 0 or depth > 64:
            return None
    if depth:
        return None
    environments = _ENVIRONMENT.findall(source)
    if any(name not in _ENVIRONMENTS | _ENV_ALIASES.keys() for _, name in environments):
        return None
    stack = []
    for kind, name in environments:
        if kind == "begin":
            stack.append(name)
        elif not stack or stack.pop() != name:
            return None
    if stack:
        return None
    source = _ENVIRONMENT.sub(lambda m: f"\\{m[1]}{{{_ENV_ALIASES.get(m[2], m[2])}}}", source)
    try:
        result = lhtml.fromstring(convert(source, display="block" if display else "inline"))
        # The converter can return unknown commands as literal identifiers rather
        # than raising. Never present that as successfully typeset mathematics.
        if result.xpath(".//merror") or re.search(r"\\[A-Za-z]+", "".join(result.itertext())):
            return None
        return result
    except Exception:
        return None  # Neither private formula text nor parser errors belong in logs.


def for_speech(html: str) -> str:
    """Replace equations with bounded structural speech, never flattened text."""
    page = lhtml.fragment_fromstring(html, create_parent="article")
    for node in list(page.xpath(f'.//math[not(ancestor::math)] | .//span[@class="{FALLBACK_CLASS}"]')):
        spoken = _spoken(node) if node.tag == "math" else None
        if not spoken or len(spoken.split()) > 80:
            spoken = SPEECH_FALLBACK
        replacement = lhtml.Element("span")
        replacement.text = f" {spoken} "
        replacement.tail = node.tail
        node.getparent().replace(node, replacement)
    return lhtml.tostring(page, encoding="unicode")


def _spoken(node: lhtml.HtmlElement, depth: int = 0) -> str | None:
    if depth > 32:
        return None
    tag = node.tag
    if tag == "mspace" and node.get("linebreak") != "newline":
        return ""
    if tag in {"mi", "mn", "mo", "mtext"} and not len(node):
        token = (node.text or "").strip()
        if token in _OPERATORS:
            return _OPERATORS[token]
        if token in _GREEK:
            return _GREEK[token]
        if re.fullmatch(r"[A-Za-z0-9]+(?:\.[0-9]+)?", token):
            return token
        return None
    if (node.text or "").strip() or any((child.tail or "").strip() for child in node):
        return None
    children = [_spoken(child, depth + 1) for child in node]
    if not children or any(child is None for child in children):
        return None
    values = [child for child in children if child is not None]
    if tag in {"math", "mrow"}:
        return " ".join(values)
    if tag == "mfrac" and len(values) == 2:
        return f"start fraction {values[0]} divided by {values[1]} end fraction"
    if tag == "msqrt":
        return f"square root of {' '.join(values)} end root"
    if tag == "mroot" and len(values) == 2:
        return f"root with index {values[1]} of {values[0]} end root"
    if tag in {"msup", "msub"} and len(values) == 2:
        label = "superscript" if tag == "msup" else "subscript"
        return f"{values[0]} {label} {values[1]} end {label}"
    if tag == "msubsup" and len(values) == 3:
        return f"{values[0]} subscript {values[1]} end subscript superscript {values[2]} end superscript"
    return None
