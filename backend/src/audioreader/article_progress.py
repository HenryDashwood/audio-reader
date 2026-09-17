"""Text-versioned article progress shared by native speech engines."""

import hashlib
import json

from fastapi import HTTPException
from sqlalchemy.orm import joinedload

from audioreader import positions
from audioreader.feeds import articles
from audioreader.models import PlaybackPosition, SavedArticle
from audioreader.schemas import ArticleBookmark, ArticleProgressState
from audioreader.text import article_text


def text_version(text: str) -> str:
    # No Unicode or whitespace normalization: offsets refer to these exact bytes.
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def bookmark(position: PlaybackPosition | None) -> ArticleBookmark | None:
    if position is None or position.article_text_version is None or position.article_offset_utf16 is None:
        return None
    return ArticleBookmark(text_version=position.article_text_version, offset_utf16=position.article_offset_utf16)


def prefix_at(text: str, offset: int) -> str:
    encoded = text.encode("utf-16-le")
    if offset < 0 or offset * 2 > len(encoded):
        raise HTTPException(422, detail="The article bookmark is outside the text.")
    try:
        return encoded[: offset * 2].decode("utf-16-le")
    except UnicodeDecodeError as error:
        raise HTTPException(422, detail="The article bookmark splits a character.") from error


async def current(session, user, episode) -> tuple[ArticleProgressState, str]:
    """Resolve current text without network work or commits inside a progress write."""
    if episode.audio_url is not None:
        raise HTTPException(422, detail="Audio episodes use podcast progress.")
    selected = await session.get(
        SavedArticle,
        (user.id, episode.id),
        options=[joinedload(SavedArticle.content)],
        populate_existing=True,
    )
    content = selected.content if selected is not None else None
    content_id = content.id if content is not None else None
    text = (
        content.text
        if content is not None
        else (
            episode.article_text
            or article_text(articles.sanitised(episode.content_html))
            or article_text(articles.sanitised(episode.description))
        )
    )
    if not text or (episode.feed_id is None and content is None):
        raise HTTPException(422, detail="Open the article to prepare its text before syncing a bookmark.")
    version = text_version(text)
    position = (await positions.positions_for(session, user, [episode.id])).get(episode.id)
    saved = bookmark(position)
    if saved is not None and saved.text_version != version:
        saved = None
    value = [
        positions.revision(user, episode.id, position),
        content_id,
        version,
        position.article_text_version if position else None,
        position.article_offset_utf16 if position else None,
    ]
    revision = hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()
    return ArticleProgressState(text_version=version, content_id=content_id, revision=revision, bookmark=saved), text


async def decorate_text(session, user, episode, read):
    # Extraction may commit; take the user lock after it, before observing the
    # selected snapshot and effective position. Old explicitly-requested text
    # remains readable but cannot replace the account's newer selected version.
    if episode.audio_url is not None:
        return read
    await positions.lock_user(session, user.id)
    progress, _ = await current(session, user, episode)
    if progress.content_id == read.content_id and progress.text_version == text_version(read.text):
        read.article_progress = progress
    return read
