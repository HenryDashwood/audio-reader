"""Explicit library filters for voice requests that are more than a title."""

from sqlalchemy import exists, select
from sqlalchemy.orm import joinedload

from audioreader.commands import service
from audioreader.models import PLAYABLE_EPISODE, Episode, PlaybackPosition
from audioreader.newsletters import companions


async def search(session, user, *, query: str, unheard: bool, kind: str | None, max_seconds: int | None):
    conditions = [Episode.feed_id.in_(companions.her_feed_ids(user.id)), PLAYABLE_EPISODE]
    if unheard:
        conditions.append(
            ~exists().where(
                PlaybackPosition.user_id == user.id,
                PlaybackPosition.episode_id == Episode.id,
                PlaybackPosition.completed.is_(True),
            )
        )
    conditions.append(
        ~exists().where(
            PlaybackPosition.user_id == user.id,
            PlaybackPosition.episode_id == Episode.id,
            PlaybackPosition.dismissed.is_(True),
        )
    )
    if kind == "article":
        conditions.append(Episode.audio_url.is_(None))
    elif kind == "audio":
        conditions.append(Episode.audio_url.is_not(None))
    if max_seconds is not None:
        conditions.append(Episode.duration_seconds <= max_seconds)
    words = service.spoken_keywords(query)
    if words:
        score = service._match_score(words)
        conditions.append(score > 0)
        order = [score.desc(), Episode.published_at.desc().nulls_last(), Episode.id.desc()]
    else:
        order = [Episode.published_at.desc().nulls_last(), Episode.id.desc()]
    episodes = list(
        await session.scalars(
            select(Episode).where(*conditions).options(joinedload(Episode.feed)).order_by(*order).limit(40)
        )
    )
    return service._to_candidates(await companions.without_feed_copies(session, episodes, user.id))
