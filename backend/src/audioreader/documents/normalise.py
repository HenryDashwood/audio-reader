"""Faithful, sanitised PDF reader content, with bounded inline figures for offline use."""

import base64
import hashlib
import io
from html import escape

from lxml import html as lhtml
from PIL import Image

from audioreader.documents import maths
from audioreader.documents.datalab import ConversionError
from audioreader.feeds import articles
from audioreader.text import article_text

MAX_HTML = 8 * 1024 * 1024


def prepare(result: dict, fallback_title: str, *, capped: bool) -> tuple[str, str, str]:
    source = result.get("html")
    if not isinstance(source, str) or not source.strip() or len(source.encode()) > MAX_HTML:
        raise ConversionError("Datalab did not return readable content within the beta size limit.")
    page = lhtml.fragment_fromstring(source, create_parent="article")
    images = result.get("images") or {}
    replacements = {}
    image_bytes = 0
    for image in list(page.xpath(".//img")):
        name = image.get("src", "")
        encoded = images.get(name) if isinstance(images, dict) else None
        alt = image.get("alt", "Figure")[:500]
        replacement = lhtml.Element("span")
        replacement.text = f"[{alt}]"
        if isinstance(encoded, str) and len(encoded) < 4 * 1024 * 1024:
            try:
                raw = base64.b64decode(encoded.split(",", 1)[-1], validate=True)
                with Image.open(io.BytesIO(raw)) as img:
                    if img.format not in {"PNG", "JPEG"} or img.width * img.height > 12_000_000:
                        raise ValueError("unsupported figure")
                    img.verify()
                    mime = "image/png" if img.format == "PNG" else "image/jpeg"
                image_bytes += len(raw)
                if image_bytes > 4 * 1024 * 1024:
                    raise ValueError("figure limit")
                token = f"MAGPIEFIGURE{hashlib.sha256(raw).hexdigest()}END"
                replacements[token] = (
                    f'<img alt="{escape(alt, quote=True)}" src="data:{mime};base64,{base64.b64encode(raw).decode()}">'
                )
                replacement.text = token
            except Exception:
                pass  # Keep a visible caption rather than a remote tracking/broken image.
        image.addprevious(replacement)
        image.drop_tree()
    # PDF output must not load scripts, frames, styles or remote image resources.
    for node in list(page.xpath(".//script | .//style | .//iframe | .//object | .//embed | .//svg")):
        node.drop_tree()
    for node in page.xpath(".//td | .//th"):
        node.tail = " " + (node.tail or "")
    title_nodes = page.xpath(".//h1")
    title = " ".join(title_nodes[0].itertext()).strip()[:500] if title_nodes else fallback_title
    maths.convert_wrappers(page)
    clean = articles.rendered(lhtml.tostring(page, encoding="unicode")) or ""
    clean = articles.sanitised(clean)
    # Extract speech before restoring images: caption markers are visible fallback text only.
    speech_html = clean
    for token, tag in replacements.items():
        clean = clean.replace(token, tag)
        speech_html = speech_html.replace(token, "")
    text = article_text(maths.for_speech(speech_html))
    if len(text.split()) < 3:
        raise ConversionError("No readable text was found in this PDF.")
    metadata = result.get("metadata") or {}
    failed_pages = metadata.get("failed_pages") if isinstance(metadata, dict) else None
    notices = []
    if failed_pages:
        notices.append("Some pages could not be read. Check the original PDF for missing content.")
    if capped:
        notices.append("This PDF may exceed the beta page limit. Only the first 200 pages were prepared.")
    if notices:
        notice = " ".join(notices)
        clean = f"<p><strong>{escape(notice)}</strong></p>" + clean
        text = notice + "\n\n" + text
    if len(clean.encode()) > MAX_HTML:
        raise ConversionError("The prepared PDF is too large for offline reading.")
    return title or fallback_title, clean, text
