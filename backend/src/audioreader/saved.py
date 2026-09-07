"""Private saved selections over stable article identities and immutable captures."""

import hashlib
import re
from datetime import UTC, datetime
from urllib.parse import urlsplit, urlunsplit

import trafilatura
from fastapi import HTTPException
from pydantic import BaseModel, Field, HttpUrl, model_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.feeds import articles
from audioreader.feeds.fetcher import MAX_ARTICLE_BYTES, FeedFetchError, fetch_public_bytes
from audioreader.models import ArticleContent, Episode, Feed, PlaybackPosition, SavedArticle, User, utcnow
from audioreader.text import article_text, word_count


class SaveRequest(BaseModel):
    saved_at: datetime | None = None
    url: HttpUrl | None = None
    episode_id: int | None = None
    title: str | None = Field(default=None, max_length=500)
    html: str | None = Field(default=None, max_length=2_000_000)

    @model_validator(mode="after")
    def one_identity(self):
        if (self.url is None) == (self.episode_id is None):
            raise ValueError("Provide either a URL or an episode ID")
        if self.saved_at is not None and self.saved_at.tzinfo is None:
            raise ValueError("The saved date must include a time zone")
        if self.url:
            normalize_url(str(self.url))
        return self


def normalize_url(url: str) -> str:
    """Only remove fragments and default ports. Queries can identify private resources."""
    parts = urlsplit(url)
    if (
        parts.scheme not in {"http", "https"}
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.port not in {None, 80, 443}
    ):
        raise ValueError("Use a public HTTP or HTTPS address without login details")
    host = parts.hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    port = parts.port
    if port and (parts.scheme, port) not in {("http", 80), ("https", 443)}:
        host += f":{port}"
    return urlunsplit((parts.scheme.lower(), host, parts.path or "/", parts.query, ""))


async def accessible_episode(session: AsyncSession, user: User, episode_id: int) -> Episode:
    episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
    if episode is not None:
        if episode.feed is not None and episode.feed.owner_user_id in {None, user.id}:
            return episode
        if await session.get(SavedArticle, (user.id, episode_id)) is not None:
            return episode
    raise HTTPException(404, detail="episode not found")


async def selection(session: AsyncSession, user: User, episode_id: int) -> SavedArticle | None:
    return await session.get(SavedArticle, (user.id, episode_id), options=[joinedload(SavedArticle.content)])


async def save(session: AsyncSession, user: User, body: SaveRequest) -> Episode:
    # Serialize this user's duplicate captures, including retries from a share extension.
    await session.execute(select(User.id).where(User.id == user.id).with_for_update())
    if body.episode_id is not None:
        episode = await accessible_episode(session, user, body.episode_id)
    else:
        assert body.url is not None
        url = normalize_url(str(body.url))
        episode = await session.scalar(select(Episode).where(Episode.canonical_url == url))
        if episode is None:
            # Never match private newsletter bodies just because they name the same URL.
            episode = await session.scalar(
                select(Episode)
                .join(Feed)
                .where(Episode.link == url, Feed.owner_user_id.is_(None))
                .order_by(Episode.id)
                .limit(1)
            )
        if episode is None:
            try:
                async with session.begin_nested():
                    episode = Episode(canonical_url=url, guid=url, link=url, title=urlsplit(url).hostname or url)
                    session.add(episode)
                    await session.flush()
            except IntegrityError:
                episode = await session.scalar(select(Episode).where(Episode.canonical_url == url))
                assert episode is not None
    saved = await selection(session, user, episode.id)
    if saved is None:
        saved = SavedArticle(
            user_id=user.id,
            episode_id=episode.id,
            saved_at=min(body.saved_at.astimezone(UTC), utcnow()) if body.saved_at else utcnow(),
        )
        session.add(saved)
    elif saved.saved_at is None:
        saved.saved_at = utcnow()
    # Capturing new material does not switch a selected snapshot, even before playback.
    if body.html or saved.content_id is None:
        await capture(session, user, episode, saved, body)
    await session.commit()
    # Ensure the nullable feed relationship is available to response rendering.
    await session.refresh(episode, attribute_names=["feed"])
    return episode


async def capture(session: AsyncSession, user: User, episode: Episode, saved: SavedArticle, body: SaveRequest) -> None:
    if episode.audio_url and not body.html:
        saved.capture_error = None
        return
    html = ""
    title = body.title or episode.title
    source = "browser" if body.html else "web"
    if body.html:
        html, extracted_title = extract(body.html, browser=True)
        title = body.title or extracted_title or title
    elif episode.feed_id is not None:
        text, html_value = await articles.content_for(session, episode, commit=False)
        if articles.known_word_count(episode):
            html = html_value or ""
            # Preserve historical speech exactly: regenerating it moves progress.
            if html and text:
                await store_capture(session, user, episode, saved, title, html, text, "feed")
                return
    elif episode.link:
        try:
            raw, _ = await fetch_public_bytes(episode.link, max_bytes=MAX_ARTICLE_BYTES)
            html, extracted_title = extract(raw.decode("utf-8", errors="replace"))
            title = extracted_title or title
        except FeedFetchError:
            pass
    text = article_text(html)
    if not text:
        if saved.content_id is None:
            saved.capture_error = "Link saved. Could not retrieve the full article."
        return
    await store_capture(session, user, episode, saved, title, html, text, source)


def extract(raw: str, *, browser: bool = False) -> tuple[str, str | None]:
    # Subscription/login interstitials are not complete articles. Structured metadata
    # is useful evidence; absence of that signal is not a guarantee of completeness.
    if not browser and '"isAccessibleForFree":false' in raw.replace(" ", "").replace("\n", ""):
        return "", None
    html = (
        trafilatura.extract(
            raw,
            output_format="html",
            include_comments=False,
            include_formatting=True,
            include_links=True,
            include_images=True,
            include_tables=True,
        )
        or ""
    )
    html = articles.sanitised(html)
    text = article_text(html)
    if word_count(text) < 120 and re.search(
        r"subscribe to (?:continue|read)|sign in to (?:continue|read)|"
        r"already a subscriber|unlock (?:this|the) article",
        text,
        re.IGNORECASE,
    ):
        return "", None
    metadata = trafilatura.extract_metadata(raw)
    return html, metadata.title[:500] if metadata and metadata.title else None


async def store_capture(session, user, episode, saved, title, html, text, source):
    html = articles.sanitised(html)
    digest = hashlib.sha256((title + "\0" + text + "\0" + html).encode()).hexdigest()
    content = await session.scalar(
        select(ArticleContent).where(
            ArticleContent.episode_id == episode.id,
            ArticleContent.owner_user_id == user.id,
            ArticleContent.digest == digest,
        )
    )
    if content is None:
        content = ArticleContent(
            episode_id=episode.id,
            owner_user_id=user.id,
            title=title,
            text=text,
            html=html,
            digest=digest,
            source=source,
        )
        session.add(content)
        await session.flush()
    if saved.content_id is None:
        saved.content = content
        saved.content_id = content.id
        position = await session.get(PlaybackPosition, (user.id, episode.id))
        if position is not None:
            # Existing feed capture used its exact historical text above. A browser
            # capture with different text cannot inherit seconds from the feed copy.
            if episode.article_text != text:
                position.position_seconds = 0
                position.completed = False
            position.content_id = content.id
    saved.capture_error = None


async def selected_content(session, user, episode_id, content_id=None):
    saved = await selection(session, user, episode_id)
    if content_id is not None:
        content = await session.get(ArticleContent, content_id)
        if content is None or content.episode_id != episode_id or content.owner_user_id not in {None, user.id}:
            raise HTTPException(404, detail="article content not found")
        return content
    return saved.content if saved else None


async def decorate(session, user, read):
    saved = await selection(session, user, read.id)
    if saved is not None:
        read.saved_at = (
            saved.saved_at.replace(tzinfo=UTC) if saved.saved_at and saved.saved_at.tzinfo is None else saved.saved_at
        )
        read.capture_error = saved.capture_error
        if saved.content is not None:
            read.content_id = saved.content.id
            read.title = saved.content.title
            read.word_count = word_count(saved.content.text)
            read.has_text = True
        elif read.audio_url is None:
            read.has_text = False
    return read


async def reconcile(session: AsyncSession, episodes: list[Episode]) -> list[Episode]:
    """Attach an unassociated identity on exact URL match, retaining its ID and captures.

    Called only for public RSS ingestion. We never promote user-supplied content
    or title to the public catalog; metadata comes from the publisher's feed.
    """
    result = []
    for incoming in episodes:
        old = None
        if incoming.link and incoming.audio_url is None:
            try:
                url = normalize_url(incoming.link)
                old = await session.scalar(
                    select(Episode).where(Episode.canonical_url == url, Episode.feed_id.is_(None)).with_for_update()
                )
            except ValueError:
                pass
        if old is not None:
            for field in ("guid", "title", "description", "content_html", "author", "published_at", "image_url"):
                setattr(old, field, getattr(incoming, field))
            # The caller assigns the feed. No snapshot or progress is changed.
            result.append(old)
        else:
            result.append(incoming)
    return result


async def voice_candidates(session, user, query="", *, unheard=False, kind=None, max_seconds=None):
    """Search private titles only inside their owner's saved selections."""
    from audioreader.commands.intents import Candidate
    from audioreader.text import search_key

    records = (
        await session.execute(
            select(SavedArticle, Episode)
            .join(Episode)
            .options(joinedload(SavedArticle.content))
            .where(SavedArticle.user_id == user.id, SavedArticle.saved_at.is_not(None))
            .order_by(SavedArticle.saved_at.desc())
        )
    ).all()
    states = {
        p.episode_id: p
        for p in await session.scalars(select(PlaybackPosition).where(PlaybackPosition.user_id == user.id))
    }
    words = search_key(query).split()
    matches = []
    for record, episode in records:
        content = record.content
        if content is None and episode.audio_url is None:
            continue
        if (kind == "article" and episode.audio_url is not None) or (kind == "audio" and episode.audio_url is None):
            continue
        state = states.get(episode.id)
        if state and (state.dismissed or (unheard and state.completed)):
            continue
        title = content.title if content else episode.title
        if words and not all(word in search_key(title) for word in words):
            continue
        seconds = (
            episode.duration_seconds
            if episode.audio_url
            else (round(word_count(content.text) / 180 * 60) if content else None)
        )
        if max_seconds is not None and (seconds is None or seconds > max_seconds):
            continue
        matches.append(
            Candidate(
                id=episode.id,
                title=title,
                feed_title="Saved",
                description=f"Saved on {record.saved_at.date()}.",
                published_at=episode.published_at,
                duration_seconds=seconds,
                is_article=episode.audio_url is None,
            )
        )
    return matches[:60]
