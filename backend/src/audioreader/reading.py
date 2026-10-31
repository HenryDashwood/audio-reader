"""Resolve the same authorized article snapshot for reading and exporting."""

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader import saved
from audioreader.feeds import articles
from audioreader.models import Episode, User
from audioreader.schemas import EpisodeTextRead
from audioreader.text import word_count


async def article(
    session: AsyncSession, user: User, episode_id: int, content_id: int | None = None
) -> tuple[Episode, EpisodeTextRead]:
    episode = await saved.accessible_episode(session, user, episode_id)
    content = await saved.selected_content(session, user, episode_id, content_id)
    if content is not None:
        return episode, EpisodeTextRead(
            episode_id=episode.id,
            content_id=content.id,
            title=content.title,
            text=content.text,
            html=content.html if content.source == "pdf" else articles.rendered(content.html),
            word_count=word_count(content.text),
        )
    if episode.feed_id is None:
        raise HTTPException(
            422, detail={"spoken_response": "The link is saved, but the article is not ready. Retry from Saved."}
        )
    text, html = await articles.content_for(session, episode)
    if not text:
        raise HTTPException(422, detail={"spoken_response": "Sorry, I could not get the text of that article."})
    return episode, EpisodeTextRead(
        episode_id=episode.id,
        title=episode.title,
        text=text,
        html=html,
        word_count=articles.known_word_count(episode),
    )
