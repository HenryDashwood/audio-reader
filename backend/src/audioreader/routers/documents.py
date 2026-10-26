"""Account-gated PDF imports. Raw uploads avoid buffering multipart bodies before auth."""

import asyncio
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field, HttpUrl
from sqlalchemy import select

from audioreader.config import settings
from audioreader.documents import service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.models import PDFDocument
from audioreader.routers.feeds import CurrentUser, Session, check_feed_operation_limit, episodes_read
from audioreader.schemas import EpisodeRead

router = APIRouter(prefix="/documents", tags=["documents"])


class Consent(BaseModel):
    granted: bool


class URLImport(BaseModel):
    url: HttpUrl
    title: str | None = Field(default=None, max_length=500)


@router.post("/resolve", dependencies=[Depends(check_feed_operation_limit)])
async def resolve(body: URLImport, session: Session, user: CurrentUser):
    import httpx

    if not await service.enabled(session, user):
        return {"pdf": False}
    try:
        async with asyncio.timeout(15):
            return {"pdf": await service.probe_pdf(str(body.url))}
    except (httpx.HTTPError, FeedFetchError, TimeoutError):
        return {"pdf": False}


@router.get("/capability")
async def capability(session: Session, user: CurrentUser):
    enabled = await service.enabled(session, user)
    return {
        "enabled": enabled,
        # Retained for older beta clients: saving a PDF is the processing confirmation.
        "consented": enabled,
        "max_bytes": settings.pdf_max_bytes,
        "max_pages": settings.pdf_max_pages,
    }


@router.put("/consent")
async def consent(body: Consent, session: Session, user: CurrentUser):
    if body.granted:
        await service.require_access(session, user)
    user.pdf_consent_version = service.CONSENT_VERSION if body.granted else None
    await session.commit()
    return await capability(session, user)


@router.post("/from-url", status_code=202, dependencies=[Depends(check_feed_operation_limit)])
async def from_url(body: URLImport, session: Session, user: CurrentUser) -> EpisodeRead:
    episode = await service.enqueue(session, user, url=str(body.url), title=body.title)
    return (await episodes_read(session, user, [episode]))[0]


@router.post("/file", status_code=202, dependencies=[Depends(check_feed_operation_limit)])
async def from_file(
    request: Request, session: Session, user: CurrentUser, filename: str = "Imported PDF"
) -> EpisodeRead:
    await service.require_access(session, user)
    if len(filename) > 500:
        raise HTTPException(422, "The PDF filename is too long.")
    raw = bytearray()
    try:
        async with asyncio.timeout(90):
            async for chunk in request.stream():
                raw.extend(chunk)
                if len(raw) > settings.pdf_max_bytes:
                    raise HTTPException(413, "Choose a PDF no larger than 25 MiB.")
    except TimeoutError:
        raise HTTPException(408, "The PDF upload timed out. Please retry.") from None
    episode = await service.enqueue(session, user, raw=bytes(raw), title=filename)
    return (await episodes_read(session, user, [episode]))[0]


async def owned(document_id: str, session: Session, user: CurrentUser) -> PDFDocument:
    doc = await session.scalar(
        select(PDFDocument).where(PDFDocument.id == document_id, PDFDocument.user_id == user.id)
    )
    if doc is None:
        raise HTTPException(404, "PDF not found")
    return doc


Document = Annotated[PDFDocument, Depends(owned)]


@router.get("/{document_id}")
async def status(document: Document, session: Session, user: CurrentUser) -> EpisodeRead:
    return (await episodes_read(session, user, [await service.episode_for(session, document)]))[0]


@router.get("/{document_id}/original")
async def original(document: Document, session: Session) -> Response:
    await session.refresh(document, attribute_names=["original"])
    if document.original is None:
        raise HTTPException(404, "This PDF was imported from a link; open the source PDF instead.")
    return Response(
        document.original,
        media_type="application/pdf",
        headers={"Cache-Control": "private, no-store", "Content-Disposition": 'attachment; filename="document.pdf"'},
    )


@router.delete("/{document_id}", status_code=204)
async def remove(document: Document, session: Session) -> None:
    await service.delete_document(session, document)
    await session.commit()
