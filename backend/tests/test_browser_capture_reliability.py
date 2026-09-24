"""Reduced publisher fixtures shared with the real WebKit capture tests."""

import base64
import json
from pathlib import Path
from xml.etree import ElementTree

import pytest
from lxml import html as lxml_html

from audioreader import saved
from audioreader.feeds import articles
from audioreader.feeds.graphics import static_svg
from audioreader.feeds.images import normalise_images
from audioreader.page_capture import publisher_body, social_title
from audioreader.text import article_text

FIXTURES = Path(__file__).resolve().parents[2] / "ios/HearfulTests/BrowserCaptureFixtures"


def fixture(name):
    raw = (FIXTURES / f"{name}.html").read_text()
    url = lxml_html.fromstring(raw).xpath('//link[@rel="canonical"]/@href')[0]
    return raw, url


@pytest.mark.parametrize("browser", [False, True])
def test_split_publisher_keeps_every_paragraph_image_and_caption(browser):
    raw, url = fixture("canary-split")
    html, title = saved.extract(raw, url=url, browser=browser)
    assert title == "A better geothermal drill"
    page = lxml_html.fromstring(html)
    assert len(page.xpath(".//p")) == 16
    text = article_text(html)
    expected = [f"{section} paragraph {index}" for section in ["Opening", "Continuation"] for index in range(8)]
    assert all(phrase in text for phrase in expected)
    assert [text.index(phrase) for phrase in expected] == sorted(text.index(phrase) for phrase in expected)
    assert page.xpath(".//img/@src") == [
        "https://www.canarymedia.com/first.jpg",
        "https://www.canarymedia.com/second.jpg",
    ]
    assert "First photograph caption." in html and "Second photograph caption." in html
    assert "<h2>How the equipment works</h2>" in html and "<li>A useful list item</li>" in html
    assert not any(word in html for word in ["Unrelated", "Newsletter", "Author biography"])


@pytest.mark.parametrize("browser", [False, True])
def test_short_gallery_uses_the_post_instead_of_its_sponsor(browser):
    raw, url = fixture("short-gallery")
    html, _ = saved.extract(raw, url=url, browser=browser)
    assert html.count("<img") == 2
    assert "waterfront walkway" in html and "whole pier to themselves" in html
    assert "Sponsored" not in html and "Posted yesterday" not in html
    assert articles.sanitised(html) == html


def test_known_publisher_layout_changes_fail_instead_of_saving_page_chrome():
    raw, url = fixture("short-gallery")
    assert saved.extract(raw.replace('class="beat-content"', 'class="unknown"'), url=url)[0] == ""
    raw, url = fixture("canary-split")
    assert saved.extract(raw.replace("<main>", "<main></main><main>"), url=url)[0] == ""


def test_generic_capture_rejects_missing_substantial_paragraphs(monkeypatch):
    paragraphs = [f"Paragraph {i}. " + "This is evidence about the main subject. " * 8 for i in range(3)]
    raw = (
        "<title>Reliable articles</title><article><h1>Reliable articles</h1>"
        + "".join(f"<p>{p}</p>" for p in paragraphs)
        + "</article>"
    )
    monkeypatch.setattr(articles, "extract_with_videos", lambda *_args, **_kwargs: f"<p>{paragraphs[0]}</p>")
    assert saved.extract(raw)[0] == ""


def test_generic_short_sponsor_is_not_a_successful_article(monkeypatch):
    monkeypatch.setattr(
        articles, "extract_with_videos", lambda *_args, **_kwargs: "<p>Sponsored by: A promotion</p><p>Today</p>"
    )
    assert saved.extract("<html><body>Page chrome</body></html>")[0] == ""


def test_chart_extraction_keeps_images_without_axis_labels_in_speech():
    raw, url = fixture("inline-charts")
    html, _ = saved.extract(raw, url=url)
    page = lxml_html.fromstring(html)
    assert len(page.xpath(".//img")) == 4
    assert page.xpath(".//img/@alt") == [f"Benchmark chart {i}" for i in range(4)]
    for src in page.xpath(".//img/@src"):
        svg = ElementTree.fromstring(base64.b64decode(src.split(",", 1)[1]))
        assert svg.get("viewBox") == "0 0 640 420"
        assert svg.get("width") == "640" and svg.get("height") == "420"
        assert svg.findall("{http://www.w3.org/2000/svg}circle")
    text = article_text(html)
    assert "Chart axis label" not in text and "Provider detail" not in text
    assert "Caption 3" in text and "final conclusion" in text
    assert articles.sanitised(html) == html


@pytest.mark.parametrize("as_image", [False, True])
def test_static_svg_is_rebuilt_without_active_content_or_external_resources(as_image):
    svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" onload="alert(1)" aria-label="A chart">
    <script>alert(1)</script><style>text { fill: url(https://evil.example/a); }</style>
    <foreignObject><div xmlns="http://www.w3.org/1999/xhtml">Untrusted HTML</div></foreignObject>
    <image href="https://evil.example/pixel"/><use href="https://evil.example/shape#id"/>
    <a href="javascript:alert(1)"><text>Bad link</text></a>
    <rect width="50" height="20" fill="url(https://evil.example/a)" style="stroke:red;filter:url(#x)"/>
    <text x="5" y="10">A safe label<animate attributeName="x" to="50"/></text></svg>"""
    source = f'<img src="data:image/svg+xml;base64,{base64.b64encode(svg.encode()).decode()}">' if as_image else svg
    clean = articles.sanitised(source)
    image = lxml_html.fromstring(clean)
    decoded = base64.b64decode(image.get("src").split(",", 1)[1]).decode()
    assert "A safe label" in decoded and 'stroke="red"' in decoded
    assert not any(
        value in decoded
        for value in [
            "evil.example",
            "script",
            "foreignObject",
            "animate",
            "onload",
            "filter",
            "href",
            "Bad link",
            "Untrusted",
        ]
    )
    assert articles.sanitised(clean) == clean


@pytest.mark.parametrize("data", ["not base64", base64.b64encode(b"<html>Bad</html>").decode(), "A" * 270001])
def test_malformed_or_oversized_chart_data_is_not_accepted(data):
    assert "data:" not in articles.sanitised(f'<p>Prose</p><img src="data:image/svg+xml;base64,{data}">')


def test_arbitrary_data_urls_and_other_html_remain_sanitized():
    clean = articles.sanitised(
        '<svg><circle r="2"/></svg><a href="data:text/html,evil">Link</a>'
        '<img src="data:text/html,evil"><script>bad()</script>'
    )
    assert "data:text" not in clean and "bad()" not in clean
    assert "data:image/svg+xml;base64," in clean


def test_svg_external_entities_are_never_resolved():
    data = (
        b'<!DOCTYPE svg [<!ENTITY private SYSTEM "file:///etc/passwd">]>'
        b'<svg xmlns="http://www.w3.org/2000/svg"><text>&private;</text><circle r="2"/></svg>'
    )
    clean = articles.sanitised(f'<img src="data:image/svg+xml;base64,{base64.b64encode(data).decode()}">')
    decoded = base64.b64decode(lxml_html.fromstring(clean).get("src").split(",", 1)[1])
    assert b"private" not in decoded and b"passwd" not in decoded and b"DOCTYPE" not in decoded


def test_svg_complexity_is_bounded():
    svg = lxml_html.fromstring("<svg>" + '<circle r="1"/>' * 5001 + "</svg>")
    assert static_svg(svg) is None


def test_svg_unknown_namespaces_do_not_escape_the_allowlist_or_crash_capture():
    clean = articles.sanitised('<svg><evil:rect onload="bad()"/><circle r="2"/></svg>')
    decoded = base64.b64decode(lxml_html.fromstring(clean).get("src").split(",", 1)[1])
    assert b"evil" not in decoded and b"bad()" not in decoded


def test_rendering_fixture_uses_the_current_sanitized_chart_representation():
    raw, _ = fixture("inline-charts")
    chart = lxml_html.fromstring(raw).xpath("//svg")[0]
    expected = lxml_html.fromstring(articles.sanitised(lxml_html.tostring(chart, encoding="unicode")))
    actual = lxml_html.fromstring((FIXTURES / "static-chart.html").read_text()).xpath("//img")[0]
    assert actual.get("src") == expected.get("src")
    assert actual.get("alt") == expected.get("alt")


def test_generic_short_illustrated_article_preserves_its_image():
    raw = """<html><head><title>Birds on a pier</title><link rel="canonical" href="https://example.com/birds">
    <meta property="og:type" content="article"></head><body><article><h1>Birds on a pier</h1>
    <figure><img src="/birds.jpg" alt="Birds"></figure>
    <p>The pier has become a gathering place for birds while it is closed for repairs.</p></article></body></html>"""
    html, _ = saved.extract(raw, url="https://example.com/birds")
    assert "https://example.com/birds.jpg" in html and "gathering place" in html


def test_real_social_article_heading_is_preserved():
    text = "The full explanation of this topic is useful to readers. " * 20
    raw = f"""<html><head><title>Writer on X: &quot;Body opening here&quot; / X</title></head>
    <body><article><div data-testid="twitterArticleTitle">An authored headline</div>
    <p>{text}</p></article></body></html>"""
    _, title = saved.extract(raw, url="https://x.com/writer/status/123")
    assert title == "An authored headline"


def test_responsive_lazy_and_picture_images_are_resolved_before_extraction():
    page = lxml_html.fromstring("""<html><head><base href="https://cdn.example/assets/"></head><body>
    <img src="data:image/gif;base64,AAAA" data-src="lazy.jpg">
    <img src="small.jpg" srcset="medium.jpg?crop=1,2 640w, large.jpg 1280w">
    <picture><source srcset="picture.jpg 2x"><img alt="Picture"></picture>
    <img src="fallback.jpg" data-src="javascript:alert(1)">
    </body></html>""")
    normalise_images(page, "https://example.com/story")
    assert page.xpath("//img/@src") == [
        f"https://cdn.example/assets/{name}" for name in ["lazy.jpg", "large.jpg", "picture.jpg", "fallback.jpg"]
    ]
    assert not page.xpath("//img/@srcset | //img/@data-src")


@pytest.mark.parametrize("case", json.loads((FIXTURES / "social-titles.json").read_text()))
def test_social_title_policy(case):
    assert social_title(case["url"], case["title"], case["text"], case.get("headline")) == case["expected"]


async def test_saving_long_social_post_compacts_title_without_shortening_body(client):
    text = "A small discovery. " + "Detailed observations about the whole story. " * 40
    raw = (
        f"<html><head><title>Writer on X: &quot;{text}&quot; / X</title></head>"
        f"<body><article><p>{text}</p></article></body></html>"
    )
    response = await client.post(
        "/saved", json={"url": "https://x.com/writer/status/123", "title": "Unhelpful supplied title", "html": raw}
    )
    assert response.status_code == 200
    item = response.json()
    assert item["title"] == "@writer: A small discovery."
    stored = (await client.get(f"/episodes/{item['id']}/text")).json()
    assert stored["text"].count("Detailed observations") == 40


@pytest.mark.parametrize("name", ["canary-split", "short-gallery", "inline-charts"])
async def test_article_envelopes_survive_storage_and_replay(client, name):
    raw, url = fixture(name)
    page = lxml_html.fromstring(raw)
    title = page.xpath("//title/text()")[0]
    body = publisher_body(page, url)
    if body is None:
        body = lxml_html.tostring(page.xpath("//article")[0], encoding="unicode")
    envelope = (
        f'<html><head><title>{title}</title><link rel="canonical" href="{url}"></head><body>{body}</body></html>'
    )
    payload = {"url": url, "html": envelope, "content_format": "article"}
    first = (await client.post("/saved", json=payload)).json()
    assert first["has_text"] and not first["capture_error"]
    content = (await client.get(f"/episodes/{first['id']}/text")).json()
    assert content["html"].count("<img") == (4 if name == "inline-charts" else 2)
    again = (await client.post("/saved/replace", json=payload)).json()
    assert first["content_id"] == again["content_id"]


def test_sidebar_inside_article_is_not_missing_body_evidence():
    raw = (FIXTURES / "article-with-sidebar.html").read_text()
    html, _ = saved.extract(raw, browser=True, url="https://example.com/article-with-sidebar")
    assert "Opening body paragraph" in html
    assert "Closing body paragraph" in html
    assert "Promoted podcast" not in html
