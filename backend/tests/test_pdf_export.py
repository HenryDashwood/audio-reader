"""Export the authorized reader snapshot, never another owner's or newer text."""

import asyncio
import hashlib
import io
from dataclasses import replace
from pathlib import Path

import pytest
from pypdf import PdfReader

from audioreader.exports import assets, service
from audioreader.exports.service import Article, ExportBusy, Exporter, ExportError
from audioreader.models import ArticleContent, Episode, Feed, SavedArticle, User
from audioreader.routers.exports import exporter


@pytest.fixture
def renderer(client):
    class Renderer:
        def __init__(self):
            self.articles = []

        async def pdf(self, article):
            self.articles.append(article)
            return b"%PDF-1.7\nexport fixture\n%%EOF"

    fake = Renderer()
    client._transport.app.dependency_overrides[exporter] = lambda: fake
    return fake


async def captured(session, user, *, owner=None, selected=True):
    episode = Episode(guid="private-capture", title="Shared title", link="https://example.com/story")
    session.add(episode)
    await session.flush()
    content = ArticleContent(
        episode_id=episode.id,
        owner_user_id=owner or user.id,
        title="科学 & Café",
        html="<p>Private captured paragraphs.</p>",
        text="Private captured paragraphs.",
        digest="a" * 64,
        source="browser",
    )
    session.add(content)
    await session.flush()
    if selected:
        session.add(SavedArticle(user_id=user.id, episode_id=episode.id, content_id=content.id))
    await session.commit()
    return episode, content


async def test_download_uses_owned_capture_title_and_safe_headers(client, session, user, renderer):
    episode, content = await captured(session, user)
    response = await client.get(f"/episodes/{episode.id}/export.pdf?content_id={content.id}")
    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-")
    assert response.headers["content-type"] == "application/pdf"
    assert response.headers["cache-control"] == "private, no-store"
    assert "filename*=UTF-8''" in response.headers["content-disposition"]
    assert "%E7%A7%91%E5%AD%A6" in response.headers["content-disposition"]
    assert renderer.articles[0].content_id == content.id
    assert renderer.articles[0].html == content.html
    assert renderer.articles[0].title == content.title
    assert renderer.articles[0].owner == str(user.id)


async def test_default_selection_and_explicit_older_capture_both_work(client, session, user, renderer):
    episode, old = await captured(session, user)
    newer = ArticleContent(
        episode_id=episode.id,
        owner_user_id=user.id,
        title="New",
        html="<p>New</p>",
        text="New",
        digest="b" * 64,
        source="browser",
    )
    session.add(newer)
    await session.flush()
    saved = await session.get(SavedArticle, (user.id, episode.id))
    saved.content_id = newer.id
    await session.commit()
    assert (await client.get(f"/episodes/{episode.id}/export.pdf")).status_code == 200
    assert renderer.articles[-1].content_id == newer.id
    assert (await client.get(f"/episodes/{episode.id}/export.pdf?content_id={old.id}")).status_code == 200
    assert renderer.articles[-1].content_id == old.id


async def test_private_content_cannot_be_exported_by_another_account(client, session, user, renderer):
    other = User(display_name="Other")
    session.add(other)
    await session.flush()
    episode, content = await captured(session, user, owner=other.id)
    response = await client.get(f"/episodes/{episode.id}/export.pdf?content_id={content.id}")
    assert response.status_code == 404
    assert not renderer.articles


async def test_private_newsletter_requires_owner_and_needs_no_original_link(client, session, user, renderer):
    feed = Feed(url="email:own", title="My newsletter", source="email", owner_user_id=user.id)
    session.add(feed)
    await session.flush()
    episode = Episode(
        feed_id=feed.id,
        guid="newsletter",
        title="Issue",
        article_text="An entire newsletter.",
        article_html="<p>An entire newsletter.</p>",
    )
    session.add(episode)
    await session.commit()
    assert (await client.get(f"/episodes/{episode.id}/export.pdf")).status_code == 200
    assert renderer.articles[0].link is None
    other = User(display_name="Other newsletter reader")
    session.add(other)
    await session.flush()
    feed.owner_user_id = other.id
    await session.commit()
    assert (await client.get(f"/episodes/{episode.id}/export.pdf")).status_code == 404
    assert len(renderer.articles) == 1


async def test_text_version_prevents_silently_exporting_changed_text(client, session, user, renderer):
    episode, content = await captured(session, user)
    path = f"/episodes/{episode.id}/export.pdf?content_id={content.id}"
    response = await client.get(path + "&text_version=" + "0" * 64)
    assert response.status_code == 409
    assert "changed" in response.json()["detail"]["spoken_response"]
    assert not renderer.articles
    version = hashlib.sha256(content.text.encode()).hexdigest()
    assert (await client.get(path + "&text_version=" + version)).status_code == 200


async def test_export_is_independent_of_pdf_import_admission(client, session, user, renderer, monkeypatch):
    from audioreader.config import settings

    monkeypatch.setattr(settings, "pdf_import_enabled", False)
    episode, _ = await captured(session, user)
    assert (await client.get(f"/episodes/{episode.id}/export.pdf")).status_code == 200


async def test_busy_response_can_be_retried_without_changing_content(client, session, user, renderer, monkeypatch):
    episode, _ = await captured(session, user)

    async def busy(article):
        raise ExportBusy("PDF export is busy. Please try again in a moment.")

    monkeypatch.setattr(renderer, "pdf", busy)
    response = await client.get(f"/episodes/{episode.id}/export.pdf")
    assert response.status_code == 503
    assert response.headers["retry-after"] == "3"


async def test_private_cache_is_versioned_bounded_and_coalesces_repeats(monkeypatch):
    calls = []

    async def fetch(*args):
        return {}

    async def render(root):
        calls.append(root)
        return b"%PDF-123", 0

    monkeypatch.setattr(assets, "fetch", fetch)
    monkeypatch.setattr(service, "render", render)
    exporter = Exporter(cache_bytes=8)
    article = Article(owner="one", episode_id=1, content_id=1, title="Title", html="<p>Text</p>", text="Text")
    await asyncio.gather(exporter.pdf(article), exporter.pdf(article))
    assert len(calls) == 1
    await exporter.pdf(replace(article, owner="two"))
    assert len(calls) == 2
    await exporter.pdf(article)  # Other account's entry evicted the first.
    assert len(calls) == 3
    await exporter.pdf(replace(article, html="<p>Different HTML, same text</p>"))
    assert len(calls) == 4
    assert all(not folder.exists() for folder in calls)


async def test_expired_cache_regenerates_without_a_sleep(monkeypatch):
    calls = []

    async def fetch(*args):
        return {}

    async def render(root):
        calls.append(root)
        return b"%PDF-123", 0

    monkeypatch.setattr(assets, "fetch", fetch)
    monkeypatch.setattr(service, "render", render)
    exporter = Exporter(cache_seconds=0)
    article = Article(owner="one", episode_id=1, content_id=None, title="Title", html="", text="Text")
    await exporter.pdf(article)
    await exporter.pdf(article)
    assert len(calls) == 2


@pytest.mark.parametrize("cancel", [False, True])
async def test_renderer_timeout_or_cancellation_kills_the_child(tmp_path, monkeypatch, cancel):
    started = asyncio.Event()

    class Process:
        returncode = None
        killed = False

        async def communicate(self):
            started.set()
            await asyncio.Event().wait()

        def kill(self):
            self.killed = True
            self.returncode = -9

        async def wait(self):
            return self.returncode

    process = Process()

    async def create(*args, **kwargs):
        assert kwargs["env"]["RAYON_NUM_THREADS"] == "1"
        return process

    monkeypatch.setattr(service.asyncio, "create_subprocess_exec", create)
    if not cancel:
        monkeypatch.setattr(service, "RENDER_TIMEOUT_SECONDS", 0)
    task = asyncio.create_task(service.render(tmp_path))
    if cancel:
        await started.wait()
        task.cancel()
    with pytest.raises(asyncio.CancelledError if cancel else ExportError):
        await task
    assert process.killed


async def test_real_packaged_renderer_produces_text_links_and_math_without_network():
    html = '<p>Exported text and <a href="https://example.com/reference">reference</a>.</p>'
    html += '<math display="block"><mfrac><mi>a</mi><msqrt><mi>b</mi></msqrt></mfrac></math>'
    data = await Exporter().pdf(
        Article(
            owner="one",
            episode_id=1,
            content_id=None,
            title="Scientific article",
            html=html,
            text="Exported text and reference.",
        )
    )
    pdf = PdfReader(io.BytesIO(data))
    assert "Scientific article" in pdf.pages[0].extract_text()
    assert "Exported text" in pdf.pages[0].extract_text()
    assert any(
        a.get_object().get("/A", {}).get("/URI") == "https://example.com/reference"
        for p in pdf.pages
        for a in p.get("/Annots", [])
    )


def test_filename_cannot_escape_its_directory():
    assert service.filename("../../科学: A/B\n C") == "科学 AB C.pdf"
    assert service.filename("../") == "Article.pdf"


def test_all_runtime_fonts_and_licenses_are_packaged():
    root = Path(service.__file__).parent
    assert (root / "article.typ").is_file()
    for font in ["Inter-Variable.ttf", "NotoSansCJKsc-Regular.otf", "NotoSansArabic.ttf", "NotoEmoji.ttf"]:
        assert (root / "fonts" / font).stat().st_size > 100_000
    assert len(list((root / "fonts").glob("*.txt"))) == 4
