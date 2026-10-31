"""Authenticated PDF downloads of the same content used by the reader."""

import hashlib
from typing import Annotated
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import reading
from audioreader.auth.dependencies import get_current_user
from audioreader.db import get_session
from audioreader.exports import assets
from audioreader.exports.service import Article, ExportBusy, Exporter, ExportError, filename
from audioreader.models import User

router = APIRouter(prefix="/episodes", tags=["exports"])


def exporter(request: Request) -> Exporter:
    return request.app.state.pdf_exporter


@router.get("/{episode_id}/export.pdf", response_class=Response)
async def export_pdf(
    episode_id: int,
    session: Annotated[AsyncSession, Depends(get_session)],
    user: Annotated[User, Depends(get_current_user)],
    renderer: Annotated[Exporter, Depends(exporter)],
    content_id: Annotated[int | None, Query(gt=0)] = None,
    text_version: Annotated[str | None, Query(pattern="^[a-f0-9]{64}$")] = None,
) -> Response:
    episode, content = await reading.article(session, user, episode_id, content_id)
    if text_version is not None and hashlib.sha256(content.text.encode()).hexdigest() != text_version:
        raise HTTPException(
            409, detail={"spoken_response": "This article has changed. Reopen it before exporting the PDF."}
        )
    article = Article(
        owner=str(user.id),
        episode_id=episode.id,
        content_id=content.content_id,
        title=content.title,
        html=content.html or "",
        text=content.text,
        link=assets.web_link(episode.link),
        author=episode.author,
        publication=episode.feed.title if episode.feed else None,
        published=episode.published_at.strftime("%d %B %Y") if episode.published_at else None,
    )
    # Release the DB connection before image fetching and rendering. No read
    # progress or PDF-import usage is changed by an export.
    await session.commit()
    try:
        data = await renderer.pdf(article)
    except ExportBusy as exc:
        raise HTTPException(503, detail={"spoken_response": str(exc)}, headers={"Retry-After": "3"}) from exc
    except ExportError as exc:
        raise HTTPException(422, detail={"spoken_response": str(exc)}) from exc
    return Response(
        data,
        media_type="application/pdf",
        headers={
            "Content-Disposition": (
                f"attachment; filename=\"Article.pdf\"; filename*=UTF-8''{quote(filename(article.title))}"
            ),
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )
