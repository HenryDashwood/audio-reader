"""Private, account-gated PDF ingestion sharing existing saved/article contracts."""

import asyncio
import hashlib
import io
import uuid
from urllib.parse import urljoin, urlsplit

import httpx
from fastapi import HTTPException
from pypdf import PdfReader
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import billing
from audioreader.config import settings
from audioreader.feeds.fetcher import (
    FEED_USER_AGENT,
    MAX_REDIRECTS,
    FeedFetchError,
    private_request,
    validate_public_url,
)
from audioreader.models import (
    ArticleContent,
    BillingCustomer,
    Episode,
    Feed,
    PDFDocument,
    PDFPageUsage,
    PDFResultDeletion,
    PDFUsage,
    PlaybackPosition,
    SavedArticle,
    User,
    utcnow,
)

CONSENT_VERSION = 1
ACTIVE = {"queued", "submitting", "processing"}


async def enabled(session: AsyncSession, user: User) -> bool:
    if not settings.pdf_import_enabled or not settings.datalab_api_key:
        return False
    return await billing.has_access(session, user)


async def require_access(session: AsyncSession, user: User) -> None:
    if not await enabled(session, user):
        raise HTTPException(
            403, "Magpie Plus is required to import PDFs. Subscribe or restore purchases in Magpie Settings."
        )


async def probe_pdf(url: str) -> bool:
    """Read only a small prefix, validating every hop even when a server ignores Range."""
    with private_request():
        async with httpx.AsyncClient(
            timeout=10, follow_redirects=False, trust_env=False, headers={"User-Agent": FEED_USER_AGENT}
        ) as client:
            for _ in range(MAX_REDIRECTS + 1):
                await validate_public_url(url)
                async with client.stream("GET", url, headers={"Range": "bytes=0-1023"}) as response:
                    if response.is_redirect:
                        location = response.headers.get("location")
                        if not location:
                            raise FeedFetchError("The PDF link has an invalid redirect.")
                        url = urljoin(url, location)
                        continue
                    response.raise_for_status()
                    prefix = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=1024):
                        prefix.extend(chunk)
                        if len(prefix) >= 1024:
                            break
                    is_pdf = b"%PDF-" in prefix[:1024]
                    if is_pdf:
                        total = response.headers.get("content-range", "").rsplit("/", 1)[-1]
                        if not total.isdigit():
                            total = response.headers.get("content-length", "")
                        if total.isdigit() and int(total) > settings.pdf_max_bytes:
                            raise HTTPException(413, "This PDF is too large. The beta accepts files up to 25 MiB.")
                    return is_pdf
    raise FeedFetchError("The PDF link redirects too many times.")


def url_hint(url: str) -> bool:
    return urlsplit(url).path.lower().endswith(".pdf")


async def should_import(session: AsyncSession, user: User, url: str, html: str | None, hint: bool) -> bool:
    known = hint or url_hint(url)
    if known:
        await require_access(session, user)
        return True
    if html or not await enabled(session, user):
        return False
    try:
        return await probe_pdf(url)
    except httpx.HTTPError, FeedFetchError:
        return False  # Existing article capture supplies its usual recovery message.


def inspect_file(raw: bytes) -> int:
    if not raw or len(raw) > settings.pdf_max_bytes or b"%PDF-" not in raw[:1024]:
        raise ValueError("Choose a PDF no larger than 25 MiB.")
    reader = PdfReader(io.BytesIO(raw))
    if reader.is_encrypted:
        raise ValueError("Password-protected PDFs are not supported. Share an unlocked copy.")
    pages = len(reader.pages)
    if not 0 < pages <= settings.pdf_max_pages:
        raise ValueError(f"Choose a PDF with 1–{settings.pdf_max_pages} pages.")
    return pages


async def enqueue(
    session: AsyncSession, user: User, *, url: str | None = None, raw: bytes | None = None, title: str | None = None
) -> Episode:
    from audioreader.saved import normalize_url, reopen_finished

    await require_access(session, user)
    try:
        url = normalize_url(url) if url else None
    except ValueError:
        raise HTTPException(422, "Use a public HTTP or HTTPS PDF link without login details.") from None
    identity = hashlib.sha256((url.encode() if url else raw) or b"").hexdigest()
    identity = ("url:" if url else "file:") + identity
    # Serialize deduplication and the private feed creation per owner.
    await session.execute(select(User.id).where(User.id == user.id).with_for_update())
    existing = await session.scalar(
        select(PDFDocument).where(PDFDocument.user_id == user.id, PDFDocument.identity == identity)
    )
    if existing:
        saved = await session.get_one(SavedArticle, (user.id, existing.episode_id))
        saved.saved_at = saved.saved_at or utcnow()
        if url:
            await reopen_finished(session, user, existing.episode_id)
        await session.commit()
        return await episode_for(session, existing)
    active = await session.scalar(
        select(PDFDocument.id).where(PDFDocument.user_id == user.id, PDFDocument.status.in_(ACTIVE)).limit(1)
    )
    if active:
        raise HTTPException(409, "Please wait for your current PDF to finish preparing.")
    if url and not await billing.unlimited(session, user):
        try:
            async with asyncio.timeout(45):
                raw = await download_pdf(url)
        except httpx.HTTPError, FeedFetchError, TimeoutError:
            raise HTTPException(422, "Magpie could not access this PDF. Share the downloaded file instead.") from None
    if url and raw is None:
        try:
            async with asyncio.timeout(20):
                valid = await probe_pdf(url)
            if not valid:
                raise HTTPException(
                    422, "This link did not return a PDF. Download it in your browser and share the file."
                )
        except httpx.HTTPError, FeedFetchError, TimeoutError:
            raise HTTPException(
                422, "Magpie could not access this PDF link. Download it in your browser and share the file."
            ) from None
        pages = None
    else:
        try:
            async with asyncio.timeout(15):
                pages = await asyncio.to_thread(inspect_file, raw or b"")
        except Exception:
            raise HTTPException(422, "Choose an unlocked, valid PDF with at most 200 pages and 25 MiB.") from None
    stored = await session.scalar(
        select(func.coalesce(func.sum(PDFDocument.byte_count), 0)).where(PDFDocument.user_id == user.id)
    )
    if (stored or 0) + len(raw or b"") > settings.pdf_storage_bytes:
        raise HTTPException(413, "PDF storage is full. Delete an imported PDF before adding another.")
    feed = await session.scalar(select(Feed).where(Feed.url == f"documents:{user.id}"))
    if feed is None:
        feed = Feed(url=f"documents:{user.id}", title="PDFs", source="document", owner_user_id=user.id)
        session.add(feed)
        await session.flush()
    document_id = str(uuid.uuid4())
    title = (title or (urlsplit(url).path.rsplit("/", 1)[-1] if url else "Imported PDF") or "PDF")[:500]
    episode = Episode(feed_id=feed.id, guid=f"document:{document_id}", title=title)
    session.add(episode)
    await session.flush()
    session.add(
        SavedArticle(
            user_id=user.id,
            episode_id=episode.id,
            saved_at=utcnow(),
            capture_error="Preparing PDF… You can close the app.",
        )
    )
    document = PDFDocument(
        id=document_id,
        user_id=user.id,
        episode_id=episode.id,
        identity=identity,
        source_url=url,
        filename=title,
        original=raw,
        byte_count=len(raw or b""),
        page_count=pages,
    )
    session.add(document)
    await billing.reserve(session, user, document_id, pages or 0)
    await session.commit()
    return await episode_for(session, document)


async def episode_for(session: AsyncSession, document: PDFDocument) -> Episode:
    episode = await session.get_one(Episode, document.episode_id)
    await session.refresh(episode, attribute_names=["feed"])
    return episode


async def retry(session: AsyncSession, user: User, document: PDFDocument) -> Episode:
    await require_access(session, user)
    await session.execute(select(User.id).where(User.id == user.id).with_for_update())
    await session.refresh(document)
    if document.status in ACTIVE or document.status == "ready":
        return await episode_for(session, document)
    active = await session.scalar(
        select(PDFDocument.id).where(PDFDocument.user_id == user.id, PDFDocument.status.in_(ACTIVE)).limit(1)
    )
    if active:
        raise HTTPException(409, "Please wait for your current PDF to finish preparing.")
    if not await billing.unlimited(session, user):
        if not document.page_count:
            raise HTTPException(422, "Share this PDF again to confirm its page count.")
        await billing.reserve(session, user, document.id, document.page_count)
    # A known receipt resumes polling; an explicit retry of an uncertain submission may charge again.
    if document.request_id:
        document.status = "processing"
    else:
        document.status = "queued"
    document.error = None
    # This timestamp bounds the current processing attempt, including explicit retries.
    document.created_at = utcnow()
    document.next_poll_at = utcnow()
    document.lease_token = None
    document.lease_until = None
    saved = await session.get_one(SavedArticle, (user.id, document.episode_id))
    saved.capture_error = "Preparing PDF… You can close the app."
    await session.commit()
    return await episode_for(session, document)


async def queue_cleanup(session: AsyncSession, request_id: str | None) -> None:
    if request_id and not await session.get(PDFResultDeletion, request_id):
        session.add(PDFResultDeletion(request_id=request_id))


async def delete_document(session: AsyncSession, document: PDFDocument) -> None:
    await queue_cleanup(session, document.request_id)
    episode_id = document.episode_id
    await session.delete(document)
    await session.flush()
    await session.execute(delete(PlaybackPosition).where(PlaybackPosition.episode_id == episode_id))
    await session.execute(delete(SavedArticle).where(SavedArticle.episode_id == episode_id))
    await session.execute(delete(ArticleContent).where(ArticleContent.episode_id == episode_id))
    await session.execute(delete(Episode).where(Episode.id == episode_id))


async def delete_all(session: AsyncSession, user: User) -> None:
    for doc in list(await session.scalars(select(PDFDocument).where(PDFDocument.user_id == user.id))):
        await delete_document(session, doc)
    for model in (PDFUsage, PDFPageUsage, BillingCustomer):
        await session.execute(delete(model).where(model.user_id == user.id))


async def download_pdf(url: str) -> bytes:
    """Count and convert the same bounded bytes; signed URLs never reach RevenueCat."""
    with private_request():
        async with httpx.AsyncClient(timeout=20, follow_redirects=False, trust_env=False) as client:
            for _ in range(MAX_REDIRECTS + 1):
                await validate_public_url(url)
                async with client.stream("GET", url) as response:
                    if response.is_redirect:
                        location = response.headers.get("location")
                        if not location:
                            raise FeedFetchError("Invalid PDF redirect")
                        url = urljoin(url, location)
                        continue
                    response.raise_for_status()
                    raw = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=65536):
                        raw.extend(chunk)
                        if len(raw) > settings.pdf_max_bytes:
                            raise HTTPException(413, "Choose a PDF no larger than 25 MiB.")
                    return bytes(raw)
    raise FeedFetchError("Too many PDF redirects")
