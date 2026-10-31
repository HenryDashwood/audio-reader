"""Semantic HTML -> Typst adapter, using the backend's existing lxml.

No CSS engine, network access, subprocess, eval, or external Typst packages.
Source text is always emitted as a quoted string, never executable Typst markup.
Unknown visible elements retain their children and report a warning.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import statistics
from copy import deepcopy
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit

# lxml supplies etree as a native extension without Python typing stubs.
import lxml.etree as etree  # ty: ignore[unresolved-import]
from lxml import html


def quote(value: str) -> str:
    value = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "\ufffd", value)
    return json.dumps(value, ensure_ascii=False)


def join(parts: list[str]) -> str:
    parts = [p for p in parts if p and p != "[]"]
    if not parts:
        return "[]"
    if len(parts) == 1:
        return parts[0]
    return "(" + ",".join(parts) + ",).join()"


def name(node: etree._Element) -> str:
    return node.tag.rsplit("}", 1)[-1].lower() if isinstance(node.tag, str) else ""


def svg_xml(node: etree._Element) -> str:
    # lxml's HTML parser lowercases foreign attributes; SVG's XML parser is
    # case-sensitive. In particular, losing viewBox clips negative coordinates.
    node = deepcopy(node)
    attributes = {
        v.lower(): v
        for v in [
            "viewBox",
            "preserveAspectRatio",
            "gradientUnits",
            "gradientTransform",
            "patternUnits",
            "patternContentUnits",
            "patternTransform",
            "markerWidth",
            "markerHeight",
            "markerUnits",
            "refX",
            "refY",
            "textLength",
            "lengthAdjust",
            "clipPathUnits",
            "filterUnits",
            "primitiveUnits",
            "stdDeviation",
        ]
    }
    tags = {
        v.lower(): v
        for v in [
            "linearGradient",
            "radialGradient",
            "clipPath",
            "textPath",
            "foreignObject",
            "feGaussianBlur",
            "feOffset",
            "feBlend",
            "feColorMatrix",
        ]
    }
    for child in node.iter():
        if not isinstance(child.tag, str):
            continue
        child.tag = tags.get(child.tag, child.tag)
        for key in list(child.attrib):
            if key in attributes:
                child.set(attributes[key], child.attrib.pop(key))
    node.set("xmlns", "http://www.w3.org/2000/svg")
    return etree.tostring(node, encoding="unicode", with_tail=False)


@dataclass
class Conversion:
    source: str
    warnings: list[str]
    counts: dict[str, int]


@dataclass
class Converter:
    warnings: set[str] = field(default_factory=set)
    counts: dict[str, int] = field(default_factory=dict)
    depth: int = 0
    anchors: dict[str, str] = field(default_factory=dict)
    emitted_anchors: set[str] = field(default_factory=set)
    asset_root: Path | None = None

    def integer(self, value: str | None, default: int, *, minimum: int = 1, maximum: int = 10000) -> int:
        try:
            return max(minimum, min(maximum, int(value or str(default))))
        except ValueError:
            self.warnings.add("Malformed numeric attribute used a safe default")
            return default

    def wrap_long_tokens(self, value: str) -> str:
        # Optional break opportunities keep long code/URLs on the page. The
        # displayed characters are unchanged; PDF copy may contain line breaks.
        return re.sub(r"\S{49,}", lambda m: "\u200b".join(m[0][i : i + 32] for i in range(0, len(m[0]), 32)), value)

    def text(self, value: str | None, *, whitespace: bool = True) -> str:
        if not value:
            return "[]"
        value = re.sub(r"[ \t\r\n\f]+", " ", value)
        if not whitespace and not value.strip():
            return "[]"
        return f"text({quote(self.wrap_long_tokens(value))})"

    def children(self, node: etree._Element, *, whitespace: bool = True) -> str:
        parts = [self.text(node.text, whitespace=whitespace)]
        for child in node:
            parts.append(self.node(child))
            parts.append(self.text(child.tail, whitespace=whitespace))
        return join(parts)

    def length(self, value: str | None, *, default: str | None = None) -> str | None:
        if not value:
            return default
        m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(px|pt|em|mm|cm|in|%)?\s*", value)
        if not m:
            self.warnings.add("Unsupported length attribute")
            return default
        number = min(float(m[1]), 10000)
        unit = m[2] or "px"
        return f"{number * 0.75:g}pt" if unit == "px" else f"{number:g}{unit}"

    def image(self, node: etree._Element) -> str:
        try:
            return self.image_checked(node)
        except (ValueError, binascii.Error, UnicodeError):
            self.warnings.add("Invalid image data replaced by its alternative text")
            return "text(" + quote("[Image unavailable: " + (node.get("alt") or "Article illustration") + "]") + ")"

    def image_checked(self, node: etree._Element) -> str:
        src = node.get("src", "")
        options = []
        for key in ["width", "height"]:
            value = self.length(node.get(key))
            if value:
                options.append(f"{key}: {value}")
        options.append("alt: " + quote(node.get("alt") or "Article illustration"))
        if src.startswith("data:image/"):
            header, data = src.split(",", 1)
            raw = base64.b64decode(data, validate=True) if ";base64" in header else unquote(data).encode()
            if header.startswith("data:image/svg+xml"):
                source = "bytes(" + quote(raw.decode("utf-8")) + ")"
                options.append('format: "svg"')
            else:
                # Typst accepts bytes; array emission avoids a base64 runtime dependency.
                source = "bytes((" + ",".join(str(b) for b in raw) + ",))"
        else:
            path = PurePosixPath(src)
            if urlsplit(src).scheme or path.is_absolute() or ".." in path.parts or not src.startswith("assets/"):
                self.warnings.add("Image outside the supplied asset bundle was not loaded")
                return f"text({quote('[Image: ' + (node.get('alt') or 'unavailable') + ']')})"
            if self.asset_root is not None:
                resolved = (self.asset_root / src).resolve()
                if not resolved.is_relative_to((self.asset_root / "assets").resolve()) or not resolved.is_file():
                    raise ValueError("Missing asset or asset outside bundle")
            source = quote(src)
        self.counts["images"] = self.counts.get("images", 0) + 1
        return "magpie-image(" + source + "," + ",".join(options) + ")"

    def table(self, node: etree._Element) -> str:
        rows = node.xpath("./tr|./thead/tr|./tbody/tr|./tfoot/tr")
        occupied: dict[tuple[int, int], bool] = {}
        columns = 1
        for y, row in enumerate(rows):
            x = 0
            for cell in row:
                if name(cell) not in {"td", "th"}:
                    continue
                while (x, y) in occupied:
                    x += 1
                width = self.integer(cell.get("colspan"), 1, maximum=40)
                height = self.integer(cell.get("rowspan"), 1, maximum=max(1, len(rows) - y))
                for cx in range(x, x + width):
                    for cy in range(y, y + height):
                        occupied[cx, cy] = True
                x += width
                columns = max(columns, x)
        if columns > 40:
            raise ValueError("Table exceeds the 40-column limit")
        column_spec = str(columns)
        inset = "5pt"
        if columns > 6 and all(
            all(c.get("colspan", "1") == "1" for c in row if name(c) in {"td", "th"}) for row in rows
        ):
            # Wide numeric tables need more room for descriptive labels than
            # numeric measurements. Derive weights from body content, without
            # article-specific titles, column names, or widths.
            lengths = [[] for _ in range(columns)]
            for row in rows[1:]:
                for index, cell in enumerate(c for c in row if name(c) in {"td", "th"}):
                    if index < columns:
                        lengths[index].append(len(" ".join(cell.itertext()).strip()))
            weights = [max(1, min(3, (statistics.median(v) if v else 5) / 8)) for v in lengths]
            if rows:
                for index, cell in enumerate(c for c in rows[0] if name(c) in {"td", "th"}):
                    if index < columns:
                        longest = max((len(word) for word in " ".join(cell.itertext()).split()), default=0)
                        weights[index] = max(weights[index], min(3, longest / 5))
            column_spec = "(" + ",".join(f"{weight:g}fr" for weight in weights) + ",)"
            inset = "3pt"
        cells = []
        for row in rows:
            row_cells = []
            for cell in row:
                if name(cell) not in {"td", "th"}:
                    continue
                content = self.children(cell)
                if name(cell) == "th":
                    content = f"strong({content})"
                options = []
                for key in ["colspan", "rowspan"]:
                    value = self.integer(cell.get(key), 1, maximum=40 if key == "colspan" else len(rows))
                    if value != 1:
                        options.append(f"{key}: {value}")
                row_cells.append("table.cell(" + ",".join(options + [content]) + ")")
            is_header = name(row.getparent()) == "thead" or all(name(c) == "th" for c in row if isinstance(c.tag, str))
            cells.extend(["table.header(" + ",".join(row_cells) + ")"] if is_header else row_cells)
        # A rowspan may cross multiple header rows: one repeated header group
        # must contain the whole section rather than one group per row.
        headers = node.xpath("./thead/tr")
        if len(headers) > 1:
            prefix = []
            for _ in headers:
                if cells and cells[0].startswith("table.header("):
                    prefix.append(cells.pop(0)[13:-1])
            if prefix:
                cells.insert(0, "table.header(" + ",".join(prefix) + ")")
        caption = node.find("caption")
        content = "text(size: 9pt, table(columns: " + column_spec + ",inset:" + inset + "," + ",".join(cells) + "))"
        if caption is not None:
            content = "figure(" + content + ",kind: table,numbering: none,caption: " + self.children(caption) + ")"
        return content

    def math(self, node: etree._Element) -> str:
        self.depth += 1
        if self.depth > 100:
            raise ValueError("MathML exceeds the depth limit")
        try:
            body = self.math_element(node)
            variant = node.get("mathvariant")
            variants = {
                "normal": "upright",
                "bold": "bold",
                "italic": "italic",
                "bold-italic": "bold",
                "double-struck": "bb",
                "script": "cal",
                "fraktur": "frak",
                "sans-serif": "sans",
                "monospace": "mono",
            }
            if variant in variants:
                body = f"math.{variants[variant]}({body})"
                if variant == "bold-italic":
                    body = f"math.italic({body})"
            elif variant:
                self.warnings.add("Unmapped MathML variant: " + variant)
            return body
        finally:
            self.depth -= 1

    def math_element(self, node: etree._Element) -> str:
        tag = name(node)
        kids = [c for c in node if isinstance(c.tag, str)]
        values = [self.math(c) for c in kids]
        text = "".join(node.itertext()).strip()
        if tag in {"math", "mrow", "mstyle", "mpadded", "semantics"}:
            if tag == "semantics":
                return values[0] if values else "[]"
            body = join(values) if values else f"text({quote(text)})"
            if kids and name(kids[0]) == "mo" and name(kids[-1]) == "mo" and kids[0].get("stretchy") == "true":
                body = f"math.lr({body})"
            for attr in node.attrib:
                if attr in {"scriptlevel", "width", "height", "depth", "lspace", "voffset"}:
                    self.warnings.add("Some MathML style/spacing attributes are not mapped")
            return body
        if tag == "mi":
            variant = next((n.get("mathvariant") for n in (node, *node.iterancestors()) if n.get("mathvariant")), None)
            if variant and variant not in {"italic", "bold-italic"}:
                return f"math.upright({quote(text)})"
            return f"math.italic({quote(text)})" if len(text) == 1 else f"math.upright({quote(text)})"
        if tag in {"mn", "mtext", "ms"}:
            return f"math.upright({quote(text)})"
        if tag == "mo":
            cls = "normal"
            if text in {"=", "≠", "<", ">", "≤", "≥", "≈", "≃", "∈", "∉", "→", "↔"}:
                cls = "relation"
            elif text in {"+", "-", "−"}:
                cls = "vary"
            elif text in {"×", "·", "÷", "∧", "∨"}:
                cls = "binary"
            elif text in {"(", "[", "{"}:
                cls = "opening"
            elif text in {")", "]", "}"}:
                cls = "closing"
            elif text in {",", ";", ":"}:
                cls = "punctuation"
            elif text in {"∑", "∏", "∫", "⋃", "⋂"}:
                cls = "large"
            glyph = f"symbol({quote(text)})" if len(text) == 1 else f"math.upright({quote(text)})"
            if cls in {"opening", "closing"}:
                return glyph
            return f"math.class({quote(cls)},{glyph})"
        if tag == "mfrac" and len(values) == 2:
            return f"math.frac({values[0]},{values[1]})"
        if tag == "mfenced":
            separators = node.get("separators", ",").replace(" ", "")
            parts = []
            for index, value in enumerate(values):
                if index and separators:
                    parts.append("symbol(" + quote(separators[min(index - 1, len(separators) - 1)]) + ")")
                parts.append(value)
            left = node.get("open", "(")
            right = node.get("close", ")")
            return (
                "math.lr("
                + join(
                    (["symbol(" + quote(left) + ")"] if left else [])
                    + parts
                    + (["symbol(" + quote(right) + ")"] if right else [])
                )
                + ")"
            )
        if tag == "menclose" and node.get("notation", "") == "updiagonalstrike":
            return "math.cancel(" + join(values) + ")"
        if tag == "msqrt":
            return f"math.sqrt({join(values)})"
        if tag == "mroot" and len(values) == 2:
            return f"math.root({values[1]},{values[0]})"
        if tag in {"msup", "msub", "msubsup"} and len(values) >= 2:
            b = values[1] if tag in {"msub", "msubsup"} else "none"
            t = values[-1] if tag in {"msup", "msubsup"} else "none"
            return f"math.attach(math.scripts({values[0]}),b:{b},t:{t})"
        if tag in {"mover", "munder", "munderover"} and len(values) >= 2:
            if tag == "mover" and node.get("accent") == "true":
                return f"math.accent({values[0]},{quote(''.join(kids[1].itertext()))})"
            b = values[1] if tag in {"munder", "munderover"} else "none"
            t = values[-1] if tag in {"mover", "munderover"} else "none"
            return f"math.attach(math.limits({values[0]}),b:{b},t:{t})"
        if tag == "mspace":
            return "h(" + (self.length(node.get("width"), default="0pt") or "0pt") + ")"
        if tag in {"none", "mprescripts", "annotation", "annotation-xml"}:
            return "[]"
        if tag == "mphantom":
            return f"hide({join(values)})"
        if tag == "mtable":
            rows = []
            for row in kids:
                rows.append("(" + ",".join(self.math(c) for c in row if name(c) == "mtd") + ",)")
            return "math.mat(delim:none," + ",".join(rows) + ")"
        if tag in {"mtr", "mtd"}:
            return join(values)
        if tag == "mmultiscripts" and values:
            base = values[0]
            prescripts = False
            args = []
            for index in range(1, len(kids)):
                if name(kids[index]) == "mprescripts":
                    prescripts = True
                    continue
                keys = ("bl", "tl") if prescripts else ("br", "tr")
                args.append(keys[len(args) % 2] + ":" + values[index])
            if len(args) <= 4 and len({x.split(":", 1)[0] for x in args}) == len(args):
                return "math.attach(" + base + "," + ",".join(args) + ")"
        self.warnings.add("MathML element needs additional coverage: " + tag)
        return join(values) if values else f"math.upright({quote(text)})"

    def node(self, node: etree._Element) -> str:
        tag = name(node)
        if not tag:
            return "[]"
        self.depth += 1
        if self.depth > 100:
            raise ValueError("HTML exceeds the depth limit")
        try:
            style = re.sub(r"\s+", "", node.get("style", "")).lower()
            if "hidden" in node.attrib or "display:none" in style or "visibility:hidden" in style:
                return "[]"
            result = self.element(node, tag)
            direction = node.get("dir")
            lang = node.get("lang")
            if lang:
                lang = lang.split("-")[0].lower()
                if not re.fullmatch("[a-z]{2,3}", lang):
                    self.warnings.add("Unsupported language tag retained without language styling")
                    lang = None
            if direction in {"ltr", "rtl"} or lang:
                args = ([f"dir:{direction}"] if direction in {"ltr", "rtl"} else []) + (
                    ["lang:" + quote(lang)] if lang else []
                )
                result = "text(" + ",".join(args + [result]) + ")"
            anchor = node.get("id") or (node.get("name") if tag == "a" else None)
            if anchor in self.anchors and anchor not in self.emitted_anchors:
                self.emitted_anchors.add(anchor)
                result = join(["[#metadata(none)#label(" + quote(self.anchors[anchor]) + ")]", result])
            return result
        finally:
            self.depth -= 1

    def element(self, node: etree._Element, tag: str) -> str:
        if tag in {"script", "style", "head", "meta", "title", "link", "annotation", "annotation-xml"}:
            return "[]"
        if tag in {"video", "audio", "canvas", "source"}:
            return self.children(node)
        if tag == "math":
            self.counts["equations"] = self.counts.get("equations", 0) + 1
            return "math.equation(block:" + str(node.get("display") == "block").lower() + "," + self.math(node) + ")"
        if tag == "img":
            return self.image(node)
        if tag == "svg":
            source = svg_xml(node)
            options = ['format: "svg"']
            for attr in ["width", "height"]:
                size = self.length(node.get(attr))
                if size:
                    options.append(attr + ":" + size)
            return "magpie-image(bytes(" + quote(source) + ")," + ",".join(options) + ")"
        if tag in {"body", "html", "article", "section", "main", "div", "details", "aside", "header", "footer"}:
            body = self.children(node, whitespace=False)
            # Paragraph breaks coalesce across nested layout wrappers. Zero-gap
            # Typst blocks can make adjacent text overlap because their spacing
            # suppresses the normal paragraph clearance.
            return (
                join(["parbreak()", body, "parbreak()"])
                if tag in {"div", "section", "aside", "header", "footer"}
                else body
            )
        if tag == "p":
            return "par(" + self.children(node) + ")"
        if tag in {
            "span",
            "time",
            "small",
            "mark",
            "abbr",
            "cite",
            "kbd",
            "samp",
            "summary",
            "bdi",
            "bdo",
            "ruby",
            "rt",
        }:
            return self.children(node)
        if tag in {"strong", "b"}:
            return "strong(" + self.children(node) + ")"
        if tag in {"em", "i"}:
            return "emph(" + self.children(node) + ")"
        if tag == "u":
            return "underline(" + self.children(node) + ")"
        if tag in {"s", "strike", "del"}:
            return "strike(" + self.children(node) + ")"
        if tag in {"sup", "sub"}:
            return ("super" if tag == "sup" else "sub") + "(" + self.children(node) + ")"
        if tag == "br":
            return "linebreak()"
        if tag == "hr":
            return "block(line(length:100%,stroke:0.5pt))"
        if tag == "pre":
            return "raw(" + quote(self.wrap_long_tokens("".join(node.itertext()))) + ",block:true)"
        if tag == "code":
            return "raw(" + quote(self.wrap_long_tokens("".join(node.itertext()))) + ")"
        if re.fullmatch("h[1-6]", tag):
            return f"heading(level:{tag[1]}," + self.children(node) + ")"
        if tag == "blockquote":
            return "quote(block:true," + self.children(node, whitespace=False) + ")"
        if tag in {"ul", "ol"}:
            items = [c for c in node if name(c) == "li"]
            start = self.integer(node.get("start"), len(items) if "reversed" in node.attrib else 1, minimum=0)
            if tag == "ol" and ("reversed" in node.attrib or any("value" in c.attrib for c in items) or start == 0):
                args = []
                value = start
                for item in items:
                    value = self.integer(item.get("value"), value, minimum=0)
                    args.append("par(" + join(["text(" + quote(str(value) + ". ") + ")", self.children(item)]) + ")")
                    value += -1 if "reversed" in node.attrib else 1
                return "block(" + join(args) + ")"
            args = [self.children(c) for c in items]
            return (
                ("enum(start:" + str(start) + "," if tag == "ol" else "list(") + "tight:true," + ",".join(args) + ")"
            )
        if tag == "li":
            return self.children(node)
        if tag == "a":
            content = self.children(node)
            href = node.get("href", "").strip()
            if href.startswith("#") and href != "#":
                target = unquote(href[1:])
                if target in self.anchors:
                    self.counts["internal_links"] = self.counts.get("internal_links", 0) + 1
                    return "link(label(" + quote(self.anchors[target]) + ")," + content + ")"
                self.warnings.add("Internal link target is missing")
                return content
            if urlsplit(href).scheme.lower() in {"http", "https", "mailto", "tel"}:
                if content != "[]":
                    self.counts["links"] = self.counts.get("links", 0) + 1
                return "link(" + quote(href) + "," + content + ")"
            if href and href != "#":
                self.warnings.add("Unmapped link scheme or internal fragment")
            return content
        if tag == "figure":
            caption = next((c for c in node if name(c) == "figcaption"), None)
            parts = [self.text(node.text, whitespace=False)]
            for c in node:
                if c is not caption:
                    parts.append(self.node(c))
                parts.append(self.text(c.tail, whitespace=False))
            return (
                "figure("
                + join(parts)
                + ",numbering:none,caption:"
                + (self.children(caption) if caption is not None else "none")
                + ")"
            )
        if tag == "figcaption":
            return self.children(node)
        if tag == "table":
            return self.table(node)
        if tag == "dl":
            return "block(" + self.children(node, whitespace=False) + ")"
        if tag == "dt":
            return "par(strong(" + self.children(node) + "))"
        if tag == "dd":
            return "block(inset:(left:12pt)," + self.children(node) + ")"
        if tag == "address":
            return "block(" + self.children(node) + ")"
        self.warnings.add("Unmapped HTML element retained as content: " + tag)
        return self.children(node)


HELPERS = """#let magpie-image(source, alt: "Article illustration", width: auto, height: auto, format: auto) = box(
context layout(size => {
  let original = image(source, alt: alt, width: width, height: height, format: format)
  let dimensions = measure(original)
  let ratio = calc.min(1, size.width / dimensions.width, 650pt / dimensions.height)
  box(image(source, alt: alt, width: dimensions.width * ratio, height: dimensions.height * ratio, format: format))
}))
"""


def convert(source: str, *, asset_root: Path | None = None) -> Conversion:
    if len(source.encode()) > 8 * 1024 * 1024:
        raise ValueError("HTML exceeds the size limit")
    root = html.fromstring(source, parser=html.HTMLParser(no_network=True))
    body = root.find("body") if name(root) == "html" else root
    if body is None:
        body = root
    anchors = {}
    for node in body.iter():
        anchor = node.get("id") or (node.get("name") if name(node) == "a" else None)
        if anchor:
            anchors[anchor] = "magpie-" + hashlib.sha256(anchor.encode()).hexdigest()[:20]
    converter = Converter(anchors=anchors, asset_root=asset_root)
    result = converter.node(body)
    return Conversion(HELPERS + "#" + result + "\n", sorted(converter.warnings), converter.counts)
