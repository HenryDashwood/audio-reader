import io
from datetime import timedelta
from unittest.mock import AsyncMock

import httpx
import pytest
import respx
from pypdf import PdfWriter
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker

from audioreader.config import settings
from audioreader.documents import datalab, normalise, service, worker
from audioreader.models import PDFDocument, PDFUsage, SavedArticle, User, UserIdentity, utcnow


@pytest.fixture
async def beta(session, user, monkeypatch):
    monkeypatch.setattr(settings, "datalab_api_key", "test-only")
    monkeypatch.setattr(settings, "pdf_import_enabled", True)
    session.add(
        UserIdentity(user_id=user.id, provider="google", provider_subject="pdf-beta", email="hcndashwood@gmail.com")
    )
    await session.commit()
    return user


def pdf():
    writer = PdfWriter()
    writer.add_blank_page(width=300, height=400)
    stream = io.BytesIO()
    writer.write(stream)
    return stream.getvalue()


async def test_gate_uses_verified_identity_not_profile(client, session, user, monkeypatch):
    monkeypatch.setattr(settings, "datalab_api_key", "test-only")
    monkeypatch.setattr(settings, "pdf_import_enabled", True)
    user.email = "hcndashwood@gmail.com"
    await session.commit()
    response = await client.post("/documents/file", content=pdf())
    assert response.status_code == 403
    assert not (await client.get("/documents/capability")).json()["enabled"]


async def test_save_is_sufficient_without_separate_consent(client, beta, session):
    beta.pdf_consent_version = None
    await session.commit()
    assert (await client.get("/documents/capability")).json()["consented"]
    response = await client.post("/documents/file?filename=Study.pdf", content=pdf())
    assert response.status_code == 202
    assert response.json()["document_status"] == "queued"


async def test_file_deduplication_and_private_access(client, beta, session, make_client):
    first = (await client.post("/documents/file", content=pdf())).json()
    second = (await client.post("/documents/file", content=pdf())).json()
    assert first["id"] == second["id"]
    assert list(await session.scalars(select(PDFUsage))) == []
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as stranger:
        assert (await stranger.get(f"/documents/{first['document_id']}")).status_code == 404
        assert (await stranger.get(f"/episodes/{first['id']}/text")).status_code == 404
        assert (await stranger.post("/saved", json={"episode_id": first["id"]})).status_code == 404
        assert (await stranger.get("/saved")).json() == []


async def test_invalid_and_oversized_files(client, beta, monkeypatch):
    assert (await client.post("/documents/file", content=b"%PDF-bad")).status_code == 422
    monkeypatch.setattr(settings, "pdf_max_bytes", 10)
    assert (await client.post("/documents/file", content=pdf())).status_code == 413


async def test_pdf_link_with_embedded_credentials_is_rejected(client, beta):
    response = await client.post("/documents/from-url", json={"url": "https://user:password@papers.example/a.pdf"})
    assert response.status_code == 422


@respx.mock
async def test_browser_share_extensionless_pdf_uses_private_job(client, beta):
    respx.get("https://papers.example/download?id=123").mock(return_value=httpx.Response(200, content=pdf()))
    response = await client.post("/saved", json={"url": "https://papers.example/download?id=123"})
    assert response.status_code == 200
    assert response.json()["document_status"] == "queued"
    assert response.json()["link"] == "https://papers.example/download?id=123"
    assert response.json()["feed_url"] is None


@respx.mock
async def test_pdf_browser_html_is_not_captured_as_article(client, beta):
    respx.get("https://papers.example/a.pdf").mock(return_value=httpx.Response(200, content=pdf()))
    response = await client.post(
        "/saved/replace", json={"url": "https://papers.example/a.pdf", "html": "<p>PDF viewer</p>"}
    )
    assert response.status_code == 200
    assert response.json()["document_id"]
    assert response.json()["content_id"] is None


@pytest.mark.parametrize("route", ["/saved", "/saved/replace"])
@respx.mock
async def test_browser_resave_reopens_finished_pdf_without_another_import(client, beta, route):
    url = "https://papers.example/a.pdf"
    respx.get(url).mock(return_value=httpx.Response(200, content=pdf()))
    first = (await client.post("/saved", json={"url": url})).json()
    state = await client.put(f"/episodes/{first['id']}/state", json={"played": True})
    assert state.status_code == 204
    response = await client.post(route, json={"url": url})
    assert response.status_code == 200
    reopened = response.json()
    assert reopened["id"] == first["id"]
    assert reopened["document_id"] == first["document_id"]
    assert reopened["saved_at"] == first["saved_at"]
    assert not reopened["completed"]
    assert reopened["position_seconds"] == 0


@respx.mock
async def test_redirect_to_private_network_rejected(client, beta, monkeypatch):
    from audioreader.feeds import fetcher

    async def resolve(host, _port):
        return {"127.0.0.1"} if host == "127.0.0.1" else {"93.184.216.34"}

    monkeypatch.setattr(fetcher, "resolve_host_addresses", resolve)
    respx.get("https://papers.example/a.pdf").mock(
        return_value=httpx.Response(302, headers={"Location": "http://127.0.0.1/admin"})
    )
    response = await client.post("/documents/from-url", json={"url": "https://papers.example/a.pdf"})
    assert response.status_code == 422


async def test_worker_publishes_immutable_private_content(client, beta, session, monkeypatch):
    assert beta.pdf_consent_version is None
    row = (await client.post("/documents/file", content=pdf())).json()
    maker = async_sessionmaker(session.bind, expire_on_commit=False)
    submit = AsyncMock(return_value="test-request")
    monkeypatch.setattr(datalab, "submit", submit)
    monkeypatch.setattr(
        datalab,
        "poll",
        AsyncMock(
            return_value={
                "status": "complete",
                "success": True,
                "page_count": 1,
                "html": "<h1>Research</h1><p>A readable scientific document.</p><script>bad()</script>",
                "json": {"children": []},
            }
        ),
    )
    assert await worker.step(maker)
    async with maker() as fresh:
        document = await fresh.get(PDFDocument, row["document_id"])
        assert document is not None
        document.next_poll_at = utcnow() - timedelta(seconds=1)
        await fresh.commit()
    assert await worker.step(maker)
    session.expire_all()
    # Refresh the dependency user before API code reads its properties.
    await session.refresh(beta)
    ready = (await client.get(f"/episodes/{row['id']}")).json()
    assert ready["document_status"] == "ready"
    result = (await client.get(f"/episodes/{row['id']}/text")).json()
    assert "readable scientific" in result["text"]
    assert "<script" not in result["html"]
    assert result["content_id"] == ready["content_id"]
    assert submit.await_count == 1
    assert (await client.post(f"/saved/{row['id']}/retry")).json()["content_id"] == ready["content_id"]


async def test_stale_submission_is_not_resubmitted(client, beta, session, monkeypatch):
    row = (await client.post("/documents/file", content=pdf())).json()
    document = await session.get(PDFDocument, row["document_id"])
    document.status = "submitting"
    document.lease_until = utcnow() - timedelta(minutes=1)
    await session.commit()
    submit = AsyncMock()
    monkeypatch.setattr(datalab, "submit", submit)
    await worker.step(async_sessionmaker(session.bind, expire_on_commit=False))
    await session.refresh(document)
    assert document.status == "failed"
    assert "twice" in document.error
    submit.assert_not_called()


async def test_delete_removes_original_and_access(client, beta, session):
    row = (await client.post("/documents/file", content=pdf())).json()
    assert (await client.get(f"/documents/{row['document_id']}/original")).content == pdf()
    assert (await client.delete(f"/documents/{row['document_id']}")).status_code == 204
    assert (await client.get(f"/episodes/{row['id']}")).status_code == 404
    assert list(await session.scalars(select(PDFDocument))) == []
    assert list(await session.scalars(select(SavedArticle))) == []
    assert list(await session.scalars(select(PDFUsage))) == []


@respx.mock
@pytest.mark.parametrize("source", ["file", "url"])
async def test_historical_usage_never_blocks_imports_or_retries(client, beta, session, source):
    session.add(PDFUsage(user_id=beta.id, pages=10000))
    await session.commit()
    if source == "url":
        respx.get("https://papers.example/new.pdf").mock(return_value=httpx.Response(200, content=pdf()))
        response = await client.post("/documents/from-url", json={"url": "https://papers.example/new.pdf"})
    else:
        response = await client.post("/documents/file", content=pdf())
    assert response.status_code == 202
    document = await session.get(PDFDocument, response.json()["document_id"])
    document.status = "failed"
    await session.commit()
    await service.retry(session, beta, document)
    assert document.status == "queued"
    assert list(await session.scalars(select(PDFUsage.pages))) == [10000]


def test_normalisation_keeps_structure_and_warns_on_missing_pages():
    title, html, text = normalise.prepare(
        {
            "html": (
                "<h1>Study</h1><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>"
                '<p>Some prose here.</p><img src="https://track.example/a"><iframe src="https://example.com"></iframe>'
            ),
            "metadata": {"failed_pages": [1]},
        },
        "Fallback",
        capped=True,
    )
    assert title == "Study"
    assert "<table>" in html
    assert "A B" in text
    assert "missing content" in text
    assert "first 200" in html
    assert "track.example" not in html
    assert "<iframe" not in html


@respx.mock
async def test_datalab_submits_url_without_browser_credentials(monkeypatch):
    monkeypatch.setattr(settings, "datalab_api_key", "test-key")
    route = respx.post(f"{datalab.API}/convert").mock(return_value=httpx.Response(200, json={"request_id": "abc-123"}))
    assert await datalab.submit("https://papers.example/a.pdf?token=private", None) == "abc-123"
    request = route.calls.last.request
    assert request.headers["X-API-Key"] == "test-key"
    assert b"file_url=" in request.content
    assert "cookie" not in request.headers


async def test_delete_during_submission_cannot_restore_document(client, beta, session, monkeypatch):
    row = (await client.post("/documents/file", content=pdf())).json()
    maker = async_sessionmaker(session.bind, expire_on_commit=False)

    async def submit(_url, _original):
        async with maker() as other:
            document = await other.get(PDFDocument, row["document_id"])
            assert document is not None
            await service.delete_document(other, document)
            await other.commit()
        return "late-result"

    monkeypatch.setattr(datalab, "submit", submit)
    await worker.step(maker)
    from audioreader.models import PDFResultDeletion

    async with maker() as fresh:
        assert await fresh.get(PDFDocument, row["document_id"]) is None
        assert await fresh.get(PDFResultDeletion, "late-result") is not None


async def test_disabled_flag_keeps_ready_content_accessible_but_blocks_new_work(client, beta, monkeypatch):
    row = (await client.post("/documents/file", content=pdf())).json()
    monkeypatch.setattr(settings, "pdf_import_enabled", False)
    assert (await client.get(f"/documents/{row['document_id']}/original")).status_code == 200
    assert (await client.post("/documents/file", content=pdf())).status_code == 403
    assert (await client.delete(f"/documents/{row['document_id']}")).status_code == 204


@respx.mock
async def test_result_download_never_receives_api_credentials(monkeypatch):
    monkeypatch.setattr(settings, "datalab_api_key", "test-key")
    respx.get(f"{datalab.API}/convert/result-1").mock(
        return_value=httpx.Response(
            200,
            json={
                "status": "complete",
                "success": True,
                "result_url": "https://storage.example/result?signature=secret",
            },
        )
    )
    download = respx.get("https://storage.example/result?signature=secret").mock(
        return_value=httpx.Response(
            200,
            json={
                "html": "<p>Readable content here.</p>",
                "json": {},
            },
        )
    )
    result = await datalab.poll("result-1")
    assert result["html"]
    assert "x-api-key" not in download.calls.last.request.headers
    assert "authorization" not in download.calls.last.request.headers


async def test_account_deletion_erases_pdf_and_preserves_provider_cleanup(client, beta, session):
    from audioreader.auth.service import delete_user
    from audioreader.models import Episode, PDFResultDeletion

    row = (await client.post("/documents/file", content=pdf())).json()
    document = await session.get(PDFDocument, row["document_id"])
    session.add(PDFUsage(user_id=beta.id, pages=200))
    document.request_id = "delete-account-result"
    await session.commit()
    await delete_user(session, beta)
    assert await session.scalar(select(PDFDocument.id)) is None
    assert await session.scalar(select(PDFUsage.id)) is None
    assert await session.scalar(select(Episode.id).where(Episode.id == row["id"])) is None
    assert await session.get(PDFResultDeletion, "delete-account-result") is not None


async def test_account_merge_moves_private_pdf_and_requires_new_consent(client, beta, session):
    from audioreader.auth.merge import combine_accounts
    from audioreader.models import Feed

    row = (await client.post("/documents/file", content=pdf())).json()
    session.add(PDFUsage(user_id=beta.id, pages=200))
    target = User(display_name="Combined", pdf_consent_version=service.CONSENT_VERSION)
    session.add(target)
    await session.flush()
    await combine_accounts(session, target, beta)
    await session.commit()
    document = await session.get(PDFDocument, row["document_id"])
    assert document.user_id == target.id
    assert target.pdf_consent_version is None
    assert await session.scalar(select(PDFUsage.user_id)) == target.id
    assert await session.scalar(select(Feed.owner_user_id).where(Feed.source == "document")) == target.id


async def test_explicit_retry_restarts_the_processing_timeout(client, beta, session):
    row = (await client.post("/documents/file", content=pdf())).json()
    document = await session.get(PDFDocument, row["document_id"])
    document.status = "failed"
    document.created_at = utcnow() - timedelta(days=1)
    document.request_id = "existing-provider-job"
    await session.commit()
    await service.retry(session, beta, document)
    assert document.status == "processing"
    assert document.created_at > utcnow() - timedelta(minutes=1)
    assert list(await session.scalars(select(PDFUsage))) == []
