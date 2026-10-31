"""Bounded public image fetching and local-only preparation for PDF exports."""

import asyncio
import base64
import hashlib
import io
import re
from pathlib import Path
from urllib.parse import unquote_to_bytes, urljoin, urlsplit

# lxml supplies etree as a native extension without Python typing stubs.
import lxml.etree as etree  # ty: ignore[unresolved-import]
from lxml import html
from PIL import Image

from audioreader.exports.html_to_typst import name, svg_xml
from audioreader.feeds import images

MAX_HTML_BYTES = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_ASSET_BYTES = 16 * 1024 * 1024
MAX_IMAGES = 64
MAX_PIXELS = 12_000_000


def page(source: str, base: str):
    if len(source.encode()) > MAX_HTML_BYTES:
        raise ValueError("Article HTML is too large")
    try:
        tree = html.fragment_fromstring(source, create_parent="article", parser=html.HTMLParser(no_network=True))
    except etree.LxmlError as exc:
        raise ValueError("Unreadable article HTML") from exc
    if sum(1 for _ in tree.iter()) > 50_000:
        raise ValueError("Article has too many elements")
    images.normalise_images(tree, base)
    return tree


async def fetch(source: str, base: str, root: Path) -> dict[str, str]:
    """Download without credentials; the existing fetcher checks each redirect."""
    # The renderer child only needs local image preparation. Keep HTTP and
    # telemetry libraries out of its startup path and address-space budget.
    from audioreader.feeds import fetcher

    tree = await asyncio.to_thread(page, source, base)
    urls = list(dict.fromkeys(tree.xpath(".//img/@src")))
    urls = [u for u in urls if images.web_image(u, base)][:MAX_IMAGES]
    destinations: dict[str, str] = {}
    semaphore = asyncio.Semaphore(4)
    used = 0
    (root / "downloads").mkdir()

    async def one(url: str) -> None:
        nonlocal used
        async with semaphore:
            try:
                async with asyncio.timeout(5):
                    raw, _ = await fetcher.fetch_public_bytes(url, max_bytes=MAX_IMAGE_BYTES)
                if used + len(raw) > MAX_ASSET_BYTES:
                    return
                used += len(raw)
                relative = "downloads/" + hashlib.sha256(url.encode()).hexdigest()
                await asyncio.to_thread((root / relative).write_bytes, raw)
                destinations[url] = relative
            except (fetcher.FeedFetchError, TimeoutError):
                # A missing figure gets a visible alternative; it must not
                # prevent sharing all of the readable article.
                return

    try:
        async with asyncio.timeout(12):
            await asyncio.gather(*(one(url) for url in urls))
    except TimeoutError:
        pass
    return destinations


def _dimension(node, key: str) -> float | None:
    style = re.search(rf"(?:^|;)\s*{key}\s*:\s*(\d+(?:\.\d+)?)px", node.get("style", ""), re.I)
    value = style[1] if style else node.get(key, "")
    if re.fullmatch(r"\d+(?:\.\d+)?(?:px)?", value):
        return min(float(value.removesuffix("px")), 10000)
    return None


def _svg(raw: bytes) -> bytes:
    if len(raw) > 1024 * 1024:
        raise ValueError("SVG exceeds export limit")
    tree = etree.fromstring(raw, parser=etree.XMLParser(resolve_entities=False, no_network=True))
    if name(tree) != "svg":
        raise ValueError("Not an SVG")
    for node in list(tree.iter()):
        if name(node) in {"script", "foreignobject", "style"}:
            if node.getparent() is not None:
                node.getparent().remove(node)
            continue
        for key, value in list(node.attrib.items()):
            local = key.rsplit("}", 1)[-1].lower()
            if local.startswith("on") or (local == "href" and not value.startswith("#")):
                del node.attrib[key]
            elif any(not target.startswith("#") for target in re.findall(r"url\(\s*['\"]?([^)'\"\s]+)", value)):
                del node.attrib[key]
    return etree.tostring(tree)


def _local_image(raw: bytes, root: Path) -> tuple[str, int | None, int | None]:
    if len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("Image exceeds export limit")
    if raw.lstrip().startswith((b"<svg", b"<?xml")):
        raw = _svg(raw)
        relative = "assets/" + hashlib.sha256(raw).hexdigest() + ".svg"
        (root / relative).write_bytes(raw)
        return relative, None, None
    with Image.open(io.BytesIO(raw)) as original:
        if original.width * original.height > MAX_PIXELS:
            raise ValueError("Image exceeds pixel limit")
        if original.width <= 2 or original.height <= 2:
            return "", 0, 0
        original.seek(0)
        image = original.convert("RGBA" if "A" in original.getbands() or "transparency" in original.info else "RGB")
        image.thumbnail((2000, 2000), Image.Resampling.LANCZOS)
        # Preserve photographic compression instead of inflating JPEGs to PNG.
        extension = ".jpg" if original.format == "JPEG" and image.mode == "RGB" else ".png"
        output = io.BytesIO()
        image.save(
            output, format="JPEG" if extension == ".jpg" else "PNG", **({"quality": 88} if extension == ".jpg" else {})
        )
        data = output.getvalue()
        relative = "assets/" + hashlib.sha256(data).hexdigest() + extension
        (root / relative).write_bytes(data)
        return relative, image.width, image.height


def prepare(source: str, base: str, downloads: dict[str, str], root: Path, title: str) -> tuple[str, int]:
    """Runs in the renderer child, including all image decoding and resizing."""
    tree = page(source, base)
    (root / "assets").mkdir()
    warnings = 0
    for node in list(tree.xpath(".//script|.//style|.//head|.//form|.//input|.//button|.//object|.//embed")):
        node.drop_tree()
    for node in list(tree.xpath(".//iframe")):
        link = html.Element("a", href=urljoin(base, node.get("src", "")))
        link.text = "Video: " + (node.get("title") or "open the original video")
        link.tail = node.tail
        node.getparent().replace(node, link)
    for node in list(tree.iter()):
        style = re.sub(r"\s+", "", node.get("style", "")).lower()
        if "hidden" in node.attrib or "display:none" in style or "visibility:hidden" in style:
            if node.getparent() is not None:
                node.drop_tree()
    # SVGs are sanitized in XML form before the HTML parser can lose their
    # case-sensitive attributes. They then use the same local image path.
    for node in list(tree.xpath('.//*[local-name()="svg"]')):
        image = html.Element(
            "img", src="data:image/svg+xml;base64," + base64.b64encode(svg_xml(node).encode()).decode()
        )
        for key in ["width", "height", "style"]:
            if node.get(key):
                image.set(key, node.get(key))
        image.set("alt", node.get("aria-label") or "Article illustration")
        image.tail = node.tail
        node.getparent().replace(node, image)
    cache: dict[str, tuple[str, int | None, int | None]] = {}
    total = 0
    for index, node in enumerate(list(tree.xpath(".//img"))):
        src = node.get("src", "")
        width, height = _dimension(node, "width"), _dimension(node, "height")
        alt = (node.get("alt") or "Article illustration")[:500]
        if (width is not None and width <= 2) or (height is not None and height <= 2):
            node.drop_tree()
            continue
        try:
            if index >= MAX_IMAGES:
                raise ValueError("Too many images")
            if src not in cache:
                if src.startswith("data:image/"):
                    header, encoded = src.split(",", 1)
                    raw = (
                        base64.b64decode(encoded, validate=True) if ";base64" in header else unquote_to_bytes(encoded)
                    )
                elif relative := downloads.get(src):
                    path = (root / relative).resolve()
                    if not path.is_relative_to((root / "downloads").resolve()):
                        raise ValueError("Invalid download path")
                    raw = path.read_bytes()
                else:
                    raise ValueError("Unavailable image")
                total += len(raw)
                if total > MAX_ASSET_BYTES:
                    raise ValueError("Images exceed export limit")
                cache[src] = _local_image(raw, root)
            path, natural_width, natural_height = cache[src]
            if not path:  # Decoded tracking pixel.
                node.drop_tree()
                continue
            node.attrib.clear()
            node.set("src", path)
            node.set("alt", alt)
            if natural_width and natural_height:
                display_width = min(natural_width, width or 590, 590)
                if height and not width:
                    display_width = min(display_width, height * natural_width / natural_height)
                display_height = display_width * natural_height / natural_width
                if display_height > 700:
                    display_width *= 700 / display_height
                    display_height = 700
                node.set("width", str(display_width))
                node.set("height", str(display_height))
            else:
                if width:
                    node.set("width", str(width))
                if height:
                    node.set("height", str(height))
        except (ValueError, OSError, etree.XMLSyntaxError, Image.DecompressionBombError):
            fallback = html.Element("span")
            fallback.text = f"[Image unavailable: {alt}]"
            fallback.tail = node.tail
            node.getparent().replace(node, fallback)
            warnings += 1
    for node in tree.iter():
        node.attrib.pop("style", None)
        if name(node) == "a":
            href = node.get("href", "").strip()
            if href and not href.startswith("#"):
                node.set("href", urljoin(base, href))
    # Avoid a duplicated title while retaining different article subheadings.
    first = next(iter(tree.xpath(".//h1")), None)
    if first is not None and " ".join(first.itertext()).strip().casefold() == title.strip().casefold():
        first.drop_tree()
    return html.tostring(tree, encoding="unicode"), warnings


def web_link(value: str | None) -> str | None:
    if value:
        try:
            parsed = urlsplit(value)
            if parsed.scheme in {"https", "http"} and parsed.hostname and not parsed.username and not parsed.password:
                return value
        except ValueError:
            pass
    return None
