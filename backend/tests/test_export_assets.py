"""Network-free tests for bounded asset preparation and the synthetic corpus."""

import base64
import io
import json
from pathlib import Path

import pytest
from lxml import html
from PIL import Image
from pypdf import PdfReader

from audioreader.exports import assets, worker
from audioreader.feeds import fetcher

FIXTURES = Path(__file__).parent / "fixtures" / "exports"
CASES = json.loads((FIXTURES / "cases.json").read_text())


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["slug"])
def test_synthetic_articles_render_with_content_and_links(tmp_path, case):
    source = (FIXTURES / (case["slug"] + ".html")).read_text()
    downloads = {}
    # The portrait is a synthetic local asset; production never reads arbitrary
    # paths from an article's HTML.
    for src in html.fragment_fromstring(source, create_parent="article").xpath(".//img/@src"):
        if src == "assets/portrait.svg":
            (tmp_path / "downloads").mkdir(exist_ok=True)
            (tmp_path / "downloads/portrait").write_bytes((FIXTURES / src).read_bytes())
            downloads[src] = "downloads/portrait"
    payload = dict(html=source, title=case["title"], downloads=downloads)
    (tmp_path / "input.json").write_text(json.dumps(payload))
    worker.run(tmp_path)
    pdf = PdfReader(tmp_path / "article.pdf")
    text = " ".join(page.extract_text() for page in pdf.pages)
    for marker in case.get("markers", []):
        assert marker in text
    for marker in case.get("forbidden", []):
        assert marker not in text
    annotations = [a.get_object() for page in pdf.pages for a in page.get("/Annots", [])]
    if "internal_links" in case:
        assert sum(bool(a.get("/Dest")) for a in annotations) == case["internal_links"]
    if "external_links" in case:
        assert sum(bool(a.get("/A", {}).get("/URI")) for a in annotations) == case["external_links"]
    if header := case.get("repeated_header"):
        assert all(header in page.extract_text() for page in pdf.pages)


def data_image(format="JPEG", size=(800, 400)):
    buffer = io.BytesIO()
    Image.new("RGB", size, "blue").save(buffer, format=format)
    return "data:image/" + format.lower() + ";base64," + base64.b64encode(buffer.getvalue()).decode()


def test_photos_stay_compressed_and_small_icons_keep_their_size(tmp_path):
    body, warnings = assets.prepare(f'<img src="{data_image()}" width="24" alt="Photo">', "", {}, tmp_path, "Title")
    node = html.fromstring(body).find("img")
    assert not warnings
    assert node.get("src").endswith(".jpg")
    assert float(node.get("width")) == 24
    assert float(node.get("height")) == 12


def test_missing_images_and_file_urls_are_visible_alternatives(tmp_path):
    source = (
        '<img src="file:///etc/passwd" alt="Local"><img src="https://example.org/missing" alt="Chart"><p>After</p>'
    )
    body, warnings = assets.prepare(source, "https://example.org/article", {}, tmp_path, "Title")
    assert warnings == 2
    assert "Local" in body and "Chart" in body and "After" in body
    assert not html.fromstring(body).xpath(".//img")


def test_tracking_pixels_are_removed_and_hidden_text_does_not_leak(tmp_path):
    source = f'<img src="{data_image(size=(1, 1))}"><p hidden>Secret</p><p>Visible</p>'
    body, warnings = assets.prepare(source, "", {}, tmp_path, "Title")
    assert not warnings and "Secret" not in body and "<img" not in body and "Visible" in body


def test_svg_cannot_load_remote_or_local_resources():
    source = (
        b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><script>secret</scri'
        b'pt><foreignObject>hidden</foreignObject><image href="file:///etc/passwd"/><path '
        b'fill="url(https://example.org/x)" onclick="bad()"/><use href="#safe"/></svg>'
    )
    result = assets._svg(source).decode()
    assert all(value not in result for value in ["script", "foreignObject", "file:", "https:", "onclick"])
    assert 'href="#safe"' in result and "viewBox" in result


def test_download_map_cannot_escape_the_workspace(tmp_path):
    outside = tmp_path / "private"
    outside.write_text("private")
    body, warnings = assets.prepare(
        '<img src="https://example.org/img" alt="Restricted">',
        "",
        {"https://example.org/img": "private"},
        tmp_path,
        "Title",
    )
    assert warnings == 1 and "Restricted" in body and "private" not in body


async def test_fetch_is_bounded_and_image_failures_do_not_abort_article(tmp_path, monkeypatch):
    calls = []

    async def fetch(url, *, max_bytes):
        calls.append((url, max_bytes))
        if url.endswith("missing"):
            raise fetcher.FeedFetchError("unavailable")
        return b"image", "image/png"

    monkeypatch.setattr(fetcher, "fetch_public_bytes", fetch)
    source = '<img src="/ok"><img src="/ok"><img src="/missing"><img src="file:///private">'
    result = await assets.fetch(source, "https://example.org/article", tmp_path)
    assert list(result) == ["https://example.org/ok"]
    assert len(calls) == 2
    assert all(limit == assets.MAX_IMAGE_BYTES for _, limit in calls)
    assert (tmp_path / result["https://example.org/ok"]).read_bytes() == b"image"
