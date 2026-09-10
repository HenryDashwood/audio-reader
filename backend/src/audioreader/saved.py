"""Private saved selections over stable article identities and immutable captures."""

import hashlib
import re
from datetime import UTC, datetime
from typing import Literal
from urllib.parse import urlsplit, urlunsplit

import trafilatura
from fastapi import HTTPException
from lxml import html as lxml_html
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
    content_format: Literal["page", "article"] = "page"

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


async def save(session: AsyncSession, user: User, body: SaveRequest, *, replace: bool = False) -> Episode:
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
        if episode is None and replace:
            raise HTTPException(404, detail="Save this article before replacing its text.")
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
    if replace:
        if saved is None or saved.saved_at is None:
            raise HTTPException(404, detail="Save this article before replacing its text.")
        if episode.audio_url or not (body.html or episode.link):
            raise HTTPException(422, detail="This item has no web article to replace.")
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
    if replace or body.html or saved.content_id is None:
        await capture(session, user, episode, saved, body, replace=replace)
    await session.commit()
    # Ensure the nullable feed relationship is available to response rendering.
    await session.refresh(episode, attribute_names=["feed"])
    return episode


async def capture(
    session: AsyncSession,
    user: User,
    episode: Episode,
    saved: SavedArticle,
    body: SaveRequest,
    *,
    replace: bool = False,
) -> None:
    if episode.audio_url and not body.html:
        saved.capture_error = None
        return
    html = ""
    capture_error = "Link saved. Could not retrieve the full article."
    title = body.title or episode.title
    source = "browser" if body.html else "web"
    if body.html:
        html, extracted_title = extract(
            body.html, browser=True, url=episode.link, article=body.content_format == "article"
        )
        title = (extracted_title if body.content_format == "article" else body.title) or extracted_title or title
    elif episode.feed_id is not None and not replace:
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
            html, extracted_title = extract(raw.decode("utf-8", errors="replace"), url=episode.link)
            title = extracted_title or title
        except FeedFetchError as exc:
            if exc.status_code in {401, 403}:
                capture_error = (
                    "Link saved. This site refused Magpie's request. "
                    "Open the page in Safari, then use Share → Magpie to save the page content."
                )
    text = article_text(html)
    if not text:
        if replace:
            raise HTTPException(
                422,
                detail="Could not replace the text. Your saved copy is unchanged. "
                "Open the original in Safari, then share to Magpie and choose Replace saved text.",
            )
        if saved.content_id is None:
            saved.capture_error = capture_error
        return
    await store_capture(session, user, episode, saved, title, html, text, source, replace=replace)


def extract(
    raw: str, *, browser: bool = False, url: str | None = None, article: bool = False
) -> tuple[str, str | None]:
    # Subscription/login interstitials are not complete articles. Structured metadata
    # is useful evidence; absence of that signal is not a guarantee of completeness.
    if not browser and '"isAccessibleForFree":false' in raw.replace(" ", "").replace("\n", ""):
        return "", None
    try:
        page = lxml_html.document_fromstring(raw)
    except Exception:
        # lxml exposes platform-specific parser exception classes from its C module.
        return "", None
    metadata = trafilatura.extract_metadata(raw)
    # Also protect URL saves and queued captures from older clients. Only Safari
    # can resolve stylesheet visibility; here we can remove explicit hidden nodes.
    for node in list(page.iter()):
        if not isinstance(node.tag, str):
            continue
        style = node.get("style", "")
        if (
            node.get("hidden") is not None
            or node.get("aria-hidden", "").lower() == "true"
            or re.search(
                r"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*(?:hidden|collapse)|"
                r"content-visibility\s*:\s*hidden)\s*(?:!important\s*)?(?:;|$)",
                style,
                re.IGNORECASE,
            )
        ):
            if node.getparent() is not None:
                node.drop_tree()
    if article:
        # This is a format declaration, not a trust boundary: sanitize everything.
        # Identity must be carried by the same envelope as the extracted body.
        canonical = page.xpath('//link[@rel="canonical"]/@href')
        bodies = page.xpath("//body/article")
        try:
            matches = len(canonical) == 1 and url and normalize_url(canonical[0]) == normalize_url(url)
        except ValueError:
            matches = False
        if not browser or not matches or len(bodies) != 1 or len(page.xpath("//article")) != 1:
            return "", None
        html = lxml_html.tostring(bodies[0], encoding="unicode")
    else:
        groups = {}
        for index, node in enumerate(page.xpath("//article[not(ancestor::article)]")):
            key = node.get("elid") or node.get("itemid") or node.get("data-article-id") or f"node-{index}"
            groups.setdefault(key, []).append(node)
        candidates = [
            nodes
            for nodes in groups.values()
            if sum(len(p.text_content().strip()) for node in nodes for p in node.xpath(".//p")) >= 350
        ]
        if len(candidates) > 1:
            hints = page.xpath('//title/text() | //meta[@property="og:title"]/@content')
            matches = []
            for nodes in candidates:
                headings = [h.text_content() for node in nodes for h in node.xpath(".//h1")]
                if any(_matching_headline(heading, hint) for heading in headings for hint in hints):
                    matches.append(nodes)
            if len(matches) != 1:
                return "", None
            for nodes in groups.values():
                if nodes is not matches[0]:
                    for node in nodes:
                        node.drop_tree()
        html = (
            trafilatura.extract(
                page,
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
    return html, metadata.title[:500] if metadata and metadata.title else None


def _matching_headline(heading: str, hint: str) -> bool:
    words = re.findall(r"\w+", heading.lower())
    other = set(re.findall(r"\w+", hint.lower()))
    return len(words) >= 3 and sum(word in other for word in words) / len(words) >= 0.75


async def store_capture(session, user, episode, saved, title, html, text, source, *, replace=False):
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
    if saved.content_id is None or (replace and saved.content_id != content.id):
        previous_text = saved.content.text if saved.content is not None else episode.article_text
        saved.content = content
        saved.content_id = content.id
        position = await session.get(PlaybackPosition, (user.id, episode.id))
        if position is not None:
            # Existing feed capture used its exact historical text above. A browser
            # capture with different text cannot inherit seconds from the feed copy.
            if previous_text != text:
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
