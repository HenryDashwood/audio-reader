import pytest
from lxml import html as lxml_html

from audioreader import saved
from audioreader.feeds import articles
from audioreader.feeds.video import embed_url, extract_with_videos
from audioreader.text import article_text


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube-nocookie.com/embed/AbCdEf123_-?autoplay=1&start=23",
        "//www.youtube.com/embed/AbCdEf123_-?start=23",
    ],
)
def test_youtube_player_keeps_start_but_never_autoplays(url):
    assert embed_url(url) == "https://www.youtube-nocookie.com/embed/AbCdEf123_-?playsinline=1&start=23"


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com.evil.test/embed/AbCdEf123_-",
        "https://www.youtube.com@evil.test/embed/AbCdEf123_-",
        "https://evil.test@www.youtube.com/embed/AbCdEf123_-",
        "https://www.youtube.com:8443/embed/AbCdEf123_-",
        "https://www.youtube.com/redirect?url=https://evil.test",
        "https://www.youtube.com/embed/%2e%2e/redirect",
        "javascript:alert(1)",
        "data:text/html,evil",
        "/embed/AbCdEf123_-",
    ],
)
def test_arbitrary_frames_are_rejected(url):
    assert embed_url(url) is None
    assert "iframe" not in articles.sanitised(f'<p>Prose</p><iframe src="{url}">Hidden</iframe>')


def test_normalisation_is_idempotent_and_does_not_change_speech():
    raw = """<p>Before &lt; after.</p><iframe src="https://www.youtube.com/embed/AbCdEf123_-?autoplay=1"
      title="A performance" srcdoc="&lt;script&gt;bad()&lt;/script&gt;" onload="bad()"
      style="position:fixed" allow="camera; microphone">Hidden player fallback</iframe><p>After.</p>"""
    clean = articles.sanitised(raw)
    frame = lxml_html.fragment_fromstring(clean, create_parent=True).xpath(".//iframe")[0]
    assert frame.get("title") == "A performance"
    assert frame.get("sandbox") == "allow-scripts allow-same-origin allow-presentation"
    assert frame.get("referrerpolicy") == "strict-origin-when-cross-origin"
    assert "autoplay" not in clean and "srcdoc" not in clean and "bad()" not in clean
    assert "camera" not in clean and "style=" not in clean
    assert article_text(clean) == "Before < after.\n\nAfter."
    assert articles.sanitised(clean) == clean


def test_vimeo_unlisted_token_survives():
    assert embed_url("https://player.vimeo.com/video/12345?h=aB12&autoplay=1") == (
        "https://player.vimeo.com/video/12345?dnt=1&h=aB12"
    )


def test_page_and_url_save_extraction_preserve_videos_in_article_order():
    before = "An introduction to music and its history. " * 30
    after = "The next section describes another performance. " * 30
    raw = f"""<html><head><title>Music</title></head><body><article><h1>Music</h1>
    <p>{before}</p><div class="youtube-wrap"><iframe src="https://www.youtube-nocookie.com/embed/AbCdEf123_-?rel=0"></iframe></div>
    <p>{after}</p></article></body></html>"""
    for clean in (articles.sanitised(extract_with_videos(raw)), saved.extract(raw)[0]):
        assert clean.index("introduction") < clean.index("<iframe") < clean.index("next section")
        assert "MAGPIEVIDEO" not in article_text(clean)
        assert len(lxml_html.fromstring(clean).xpath(".//iframe")) == 1


@pytest.mark.parametrize("same_text", [True, False])
async def test_cached_feed_players_are_restored_only_without_changing_narration(same_text):
    from unittest.mock import AsyncMock

    from audioreader.models import Episode

    session = AsyncMock()
    episode = Episode(
        guid="video-article",
        title="Music",
        article_text="Historical prose.",
        article_html="<p>Historical prose.</p>",
        content_html=("<p>Historical prose.</p>" if same_text else "<p>Revised prose.</p>")
        + '<iframe src="https://www.youtube.com/embed/AbCdEf123_-"></iframe>',
    )
    text, html = await articles.content_for(session, episode)
    assert text == "Historical prose."
    assert html is not None
    assert ("<iframe" in html) == same_text
    assert session.commit.await_count == int(same_text)
