"""Render a deliberately small, inert subset of SVG as self-contained images.

Readers already support image data URLs. Keeping chart labels inside an image
also keeps them out of narration and text-offset/bookmark calculations.
"""

import base64
import binascii
import re
from uuid import uuid4

from lxml import etree  # ty: ignore[unresolved-import] -- lxml.etree is a compiled extension without stubs.
from lxml import html as lxml_html

_PREFIX = "data:image/svg+xml;base64,"
_NS = "http://www.w3.org/2000/svg"
_TAGS = {
    "svg",
    "g",
    "path",
    "rect",
    "circle",
    "ellipse",
    "line",
    "polyline",
    "polygon",
    "text",
    "tspan",
    "title",
    "desc",
}
_NUMBERS = {
    "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry", "dx", "dy", "width", "height",
    "opacity", "fill-opacity", "stroke-opacity", "stroke-width", "stroke-miterlimit", "stroke-dashoffset",
    "stroke-dasharray", "font-size", "letter-spacing", "word-spacing", "textLength",
}  # fmt: skip
_ENUMS = {
    "text-anchor": {"start", "middle", "end"},
    "font-weight": {"normal", "bold", *map(str, range(100, 1000, 100))},
    "font-style": {"normal", "italic", "oblique"},
    "fill-rule": {"nonzero", "evenodd"},
    "stroke-linecap": {"butt", "round", "square"},
    "stroke-linejoin": {"miter", "round", "bevel"},
    "dominant-baseline": {"auto", "middle", "central", "hanging", "alphabetic", "text-before-edge", "text-after-edge"},
}


def _attribute(name: str, value: str) -> str | None:
    if len(value) > 16000:
        return None
    if name in _NUMBERS and re.fullmatch(r"[-+0-9.eE%,\s]+(?:px|em|pt)?", value):
        return value
    if name in {"fill", "stroke", "color"} and re.fullmatch(
        r"#[0-9a-fA-F]{3,8}|[A-Za-z]+|(?:rgb|rgba|hsl|hsla)\([-+0-9.% ,]+\)", value
    ):
        return value
    if name in _ENUMS and value in _ENUMS[name]:
        return value
    if name == "font-family" and re.fullmatch(r"[\w\s,'-]+", value):
        return value
    if name == "d" and re.fullmatch(r"[MmZzLlHhVvCcSsQqTtAa0-9eE.,+\s-]+", value):
        return value
    if name == "points" and re.fullmatch(r"[-+0-9.eE,\s]+", value):
        return value
    if name == "transform" and re.fullmatch(
        r"\s*(?:(?:matrix|translate|scale|rotate|skewX|skewY)\([-+0-9.eE,\s]+\)[,\s]*)+", value
    ):
        return value
    return None


def static_svg(node) -> bytes | None:
    """Rebuild rather than strip: no URLs, IDs, CSS, HTML or active SVG survive."""
    if len(etree.tostring(node)) > 200_000 or sum(1 for _ in node.iter()) > 5000:
        return None

    def copy(source, depth=0):
        if not isinstance(source.tag, str) or depth > 40:
            return None
        tag = source.tag.removeprefix(f"{{{_NS}}}")
        if tag not in _TAGS or (depth and tag == "svg"):
            return None
        target = etree.Element(f"{{{_NS}}}{tag}", nsmap={None: _NS} if not depth else None)
        attrs = dict(source.attrib)
        for declaration in source.get("style", "").split(";"):
            name, separator, value = declaration.partition(":")
            if separator:
                attrs.setdefault(name.strip(), value.strip())
        for name, value in sorted(attrs.items()):
            safe = _attribute(name, value.strip())
            if safe is not None:
                target.set(name, safe)
        # Text only belongs in text elements; discard script/foreignObject tails.
        if tag in {"text", "tspan", "title", "desc"}:
            target.text = source.text
        for child in source:
            result = copy(child, depth + 1)
            if result is not None:
                if tag in {"text", "tspan"}:
                    result.tail = child.tail
                target.append(result)
        return target

    root = copy(node)
    if root is None or not len(root):
        return None
    viewbox = node.get("viewBox", node.get("viewbox", ""))
    if re.fullmatch(r"[-+0-9.eE,\s]+", viewbox):
        try:
            values = [float(v) for v in re.split(r"[,\s]+", viewbox.strip())]
            if len(values) == 4 and all(abs(v) < 100_000 for v in values) and min(values[2:]) > 0:
                root.set("viewBox", " ".join(f"{v:g}" for v in values))
                # Percent sizes have no intrinsic image dimensions. Use the viewBox.
                root.set("width", f"{values[2]:g}")
                root.set("height", f"{values[3]:g}")
        except ValueError:
            pass
    # Standalone images cannot inherit the reader's currentColor. Give charts a
    # readable canvas in both reader themes, without carrying publisher CSS.
    root.set("style", "background:white;color:black")
    root.set("color", "black")
    for element in root.iter():
        attributes = sorted(element.attrib.items())
        element.attrib.clear()
        element.attrib.update(attributes)
    return etree.tostring(root, encoding="utf-8")


def protect_graphics(source: str) -> tuple[str, dict[str, str]]:
    """Replace sanitized chart images with unguessable URLs during nh3 cleaning.

    Do not enable arbitrary data: URLs in nh3. Previously generated images are
    decoded and rebuilt too, so repeated sanitization stays safe and stable.
    """
    if "<svg" not in source.lower() and _PREFIX not in source:
        return source, {}
    page = lxml_html.fragment_fromstring(source, create_parent="div")
    replacements = {}
    for node in list(page.xpath('.//svg | .//img[starts-with(@src, "data:image/svg+xml;base64,")]')):
        svg = node
        if node.tag == "img":
            encoded = node.get("src", "")[len(_PREFIX) :]
            try:
                if len(encoded) > 270_000:
                    raise ValueError("Oversized chart")
                svg = etree.fromstring(
                    base64.b64decode(encoded, validate=True),
                    parser=etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False),
                )
                if svg.tag != f"{{{_NS}}}svg":
                    raise ValueError("Not an SVG image")
            except (ValueError, binascii.Error, etree.XMLSyntaxError):
                node.drop_tree()
                continue
        data = static_svg(svg)
        if data is None:
            node.drop_tree()
            continue
        description = (
            node.get("alt")
            or svg.get("aria-label")
            or " ".join(svg.xpath('./*[local-name()="title" or local-name()="desc"]/text()'))
        )
        image = lxml_html.Element("img", alt=description.strip()[:1000] or "Chart")
        image.set("src", _PREFIX + base64.b64encode(data).decode("ascii"))
        token = f"https://magpie.invalid/chart/{uuid4().hex}"
        replacements[token] = image.get("src")
        image.set("src", token)
        image.tail = node.tail
        node.getparent().replace(node, image)
    return lxml_html.tostring(page, encoding="unicode")[5:-6], replacements
