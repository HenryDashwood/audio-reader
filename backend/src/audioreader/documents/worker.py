"""Database-leased conversion steps; network requests never hold database locks."""

import asyncio
import hashlib
import json
import logging
import uuid
import zlib
from datetime import timedelta

import httpx
from sqlalchemy import func, or_, select

from audioreader.config import settings
from audioreader.documents import datalab, normalise, service
from audioreader.models import ArticleContent, PDFDocument, PDFResultDeletion, SavedArticle, User, utcnow

logger = logging.getLogger(__name__)


async def step(maker) -> bool:
    token = str(uuid.uuid4())
    now = utcnow()
    async with maker() as session:
        doc = await session.scalar(
            select(PDFDocument)
            .where(
                PDFDocument.status.in_(service.ACTIVE),
                PDFDocument.next_poll_at <= now,
                or_(PDFDocument.lease_until.is_(None), PDFDocument.lease_until < now),
            )
            .order_by(PDFDocument.created_at)
            .with_for_update(skip_locked=True)
            .limit(1)
        )
        if doc is None:
            return False
        # A process died after claiming an external submission. Never resubmit automatically.
        if doc.status == "submitting":
            doc.status = "failed"
            doc.error = "Submission could not be confirmed. Retrying may process the PDF twice."
            saved = await session.get(SavedArticle, (doc.user_id, doc.episode_id))
            if saved:
                saved.capture_error = doc.error
            await session.commit()
            return True
        user = await session.get(User, doc.user_id)
        if doc.status == "queued" and (user is None or not await service.enabled(session, user)):
            doc.status = "failed"
            doc.error = "PDF importing is not enabled for this account."
            saved = await session.get(SavedArticle, (doc.user_id, doc.episode_id))
            if saved:
                saved.capture_error = doc.error
            await session.commit()
            return True
        owner_id = doc.user_id
        submitting = doc.status == "queued"
        if submitting:
            doc.status = "submitting"
        doc.lease_token = token
        doc.lease_until = now + timedelta(minutes=3)
        identifier, request_id, url, title, known_pages = (
            doc.id,
            doc.request_id,
            doc.source_url,
            doc.filename,
            doc.page_count,
        )
        original = None
        if submitting and not url:
            await session.refresh(doc, attribute_names=["original"])
            original = doc.original
        await session.commit()
    provider_id = None
    result = None
    prepared = None
    error = None
    temporary = False
    expired = False
    try:
        async with asyncio.timeout(100):
            if submitting:
                if url:
                    # Recheck before asking the provider to fetch; probe never carries browser credentials.
                    if not await service.probe_pdf(url):
                        raise datalab.ConversionError(
                            "This PDF link has expired or changed. Share a fresh link or the file."
                        )
                provider_id = await datalab.submit(url, original)
            else:
                result = await datalab.poll(request_id)
                if result.get("success") is False or result.get("status") == "failed":
                    raise datalab.ConversionError(
                        "Datalab could not read this PDF. Try sharing an unlocked downloaded copy."
                    )
                if result.get("status") == "complete":
                    prepared = await asyncio.to_thread(
                        normalise.prepare,
                        result,
                        title,
                        capped=known_pages is None and (result.get("page_count") or 0) >= settings.pdf_max_pages,
                    )
    except datalab.ConversionError as exc:
        error = str(exc)
        expired = not submitting and bool(
            result and (result.get("success") is False or result.get("status") == "failed")
        )
    except httpx.HTTPStatusError as exc:
        expired = not submitting and exc.response.status_code in {404, 410}
        error = (
            "The previous conversion is unavailable. Retry to process this PDF again."
            if expired
            else "PDF preparation could not finish. Retry from Saved."
        )
        temporary = not submitting and not expired
    except Exception:
        error = (
            "Submission could not be confirmed. Retrying may process the PDF twice."
            if submitting
            else "PDF preparation could not finish. Retry from Saved."
        )
        temporary = not submitting
    async with maker() as session:
        await session.execute(select(User.id).where(User.id == owner_id).with_for_update())
        doc = await session.scalar(select(PDFDocument).where(PDFDocument.id == identifier).with_for_update())
        if (
            doc is None
            or doc.user_id != owner_id
            or doc.lease_token != token
            or (doc.lease_until is not None and doc.lease_until.replace(tzinfo=now.tzinfo) <= utcnow())
        ):
            if provider_id:
                await service.queue_cleanup(session, provider_id)
                await session.commit()
            return True
        saved = await session.get(SavedArticle, (doc.user_id, doc.episode_id))
        if expired:
            await service.queue_cleanup(session, doc.request_id)
            doc.request_id = None
        if error:
            # Polling is safe to retry, but stop after a bounded window.
            age = now - doc.created_at.replace(tzinfo=now.tzinfo)
            if temporary and age < timedelta(hours=12):
                doc.next_poll_at = utcnow() + timedelta(seconds=60)
            else:
                doc.status = "failed"
                doc.error = error
                if saved:
                    saved.capture_error = error
        elif provider_id:
            doc.request_id = provider_id
            doc.status = "processing"
            doc.next_poll_at = utcnow() + timedelta(seconds=5)
        elif prepared:
            assert result is not None
            title, html, text = prepared
            compressed = zlib.compress(json.dumps(result).encode())
            extra_bytes = len(compressed) + len(html.encode()) + len(text.encode())
            stored_bytes = await session.scalar(
                select(func.coalesce(func.sum(PDFDocument.byte_count), 0)).where(PDFDocument.user_id == doc.user_id)
            )
            if (stored_bytes or 0) + extra_bytes > settings.pdf_storage_bytes:
                doc.status = "failed"
                doc.error = "PDF storage is full. Delete an imported PDF, then retry."
                if saved:
                    saved.capture_error = doc.error
                doc.lease_token = None
                doc.lease_until = None
                await session.commit()
                return True
            doc.byte_count += extra_bytes
            content = ArticleContent(
                episode_id=doc.episode_id,
                owner_user_id=doc.user_id,
                title=title,
                html=html,
                text=text,
                source="pdf",
                digest=hashlib.sha256((title + "\0" + html + "\0" + text).encode()).hexdigest(),
            )
            session.add(content)
            await session.flush()
            if saved:
                saved.content_id = content.id
                saved.capture_error = None
            doc.status = "ready"
            doc.page_count = result.get("page_count") or known_pages
            # Retain the raw structured result privately for re-normalisation and diagnostics.
            doc.raw_result = compressed
            await service.queue_cleanup(session, doc.request_id)
        else:
            if now - doc.created_at.replace(tzinfo=now.tzinfo) > timedelta(hours=12):
                doc.status = "failed"
                doc.error = "PDF preparation timed out. Retry from Saved."
                if saved:
                    saved.capture_error = doc.error
            doc.next_poll_at = utcnow() + timedelta(seconds=10)
        doc.lease_token = None
        doc.lease_until = None
        await session.commit()
    return True


async def cleanup(maker) -> None:
    async with maker() as session:
        row = await session.scalar(
            select(PDFResultDeletion).where(PDFResultDeletion.next_attempt_at <= utcnow()).limit(1)
        )
        if row is None:
            return
        identifier = row.request_id
        row.next_attempt_at = utcnow() + timedelta(minutes=5)
        await session.commit()
    try:
        await datalab.delete_result(identifier)
    except (httpx.HTTPError, datalab.ConversionError, ValueError):
        return
    async with maker() as session:
        row = await session.get(PDFResultDeletion, identifier)
        if row:
            await session.delete(row)
            await session.commit()


async def run(maker) -> None:
    while True:
        try:
            if settings.datalab_api_key:
                await step(maker)
                await cleanup(maker)
        except asyncio.CancelledError:
            raise
        except Exception:
            # No exception payloads: HTTP/SQL exceptions may contain private input.
            logger.warning("PDF worker step failed; durable work will be retried")
        await asyncio.sleep(3)
