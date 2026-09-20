"""Explicit library filters for voice requests that are more than a title."""

from sqlalchemy import exists, select
from sqlalchemy.orm import joinedload

from audioreader.commands import service
from audioreader.feeds import groups
from audioreader.models import PLAYABLE_EPISODE, Episode, PlaybackPosition
from audioreader.newsletters import companions


async def search(
    session,
    user,
    *,
    query: str,
    unheard: bool,
    kind: str | None,
    max_seconds: int | None,
    saved_only: bool = False,
    feed_id: int | None = None,
    published_after=None,
    published_before=None,
    oldest: bool = False,
    chronological: bool = False,
    external_feed: bool = False,
):
    from audioreader.saved import voice_candidates

    captures = await voice_candidates(
        session,
        user,
        query,
        unheard=unheard,
        kind=kind,
        max_seconds=max_seconds,
        feed_id=feed_id,
        published_after=published_after,
        published_before=published_before,
        oldest=oldest,
        chronological=chronological,
    )
    if saved_only:
        return captures
    group = await groups.catalog(session, user.id)
    states = await service.positions.positions_for(session, user, group.copies)
    hidden = [item_id for item_id, state in states.items() if state.dismissed or (unheard and state.completed)]
    conditions = [
        Episode.feed_id == feed_id if external_feed else Episode.feed_id.in_(companions.her_feed_ids(user.id)),
        PLAYABLE_EPISODE,
        Episode.id.not_in(group.excluded_ids + hidden),
    ]
    if feed_id is not None:
        conditions.append(Episode.feed_id == feed_id)
    if published_after is not None:
        conditions.append(Episode.published_at >= published_after)
    if published_before is not None:
        conditions.append(Episode.published_at < published_before)
    if unheard:
        conditions.append(
            ~exists().where(
                PlaybackPosition.user_id == user.id,
                PlaybackPosition.episode_id == Episode.id,
                Episode.feed_id.not_in(group.roots),
                PlaybackPosition.completed.is_(True),
            )
        )
    conditions.append(
        ~exists().where(
            PlaybackPosition.user_id == user.id,
            PlaybackPosition.episode_id == Episode.id,
            Episode.feed_id.not_in(group.roots),
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
    if chronological:
        order = [Episode.published_at.desc().nulls_last(), Episode.id.desc()]
    if oldest:
        order = [Episode.published_at.asc().nulls_last(), Episode.id.asc()]
    episodes = list(
        await session.scalars(
            select(Episode).where(*conditions).options(joinedload(Episode.feed)).order_by(*order).limit(40)
        )
    )
    candidates = service._to_candidates(await companions.without_feed_copies(session, episodes, user.id))
    by_id = {candidate.id: candidate for candidate in candidates}
    by_id.update({candidate.id: candidate for candidate in captures})
    return list(by_id.values())
