"""Per-user playback positions: one row per (user, episode), last write wins.

Also where an episode is filed: heard, put aside, or back in the list.
"""

import hashlib
import json
from collections.abc import Iterable
from datetime import UTC

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.feeds import groups
from audioreader.models import PlaybackPosition, SavedArticle, User, utcnow


async def lock_user(session: AsyncSession, user_id) -> None:
    # All playback/filing/grouping writers take this before reading effective state.
    # PostgreSQL serializes even the first write, where no position row exists yet.
    # Account linking already locks its users in a stable order.
    await session.scalar(select(User.id).where(User.id == user_id).with_for_update())
    session.info.pop("feed_group_catalog", None)


def revision(user: User, episode_id: int, position: PlaybackPosition | None) -> str:
    stamp = position.updated_at if position is not None else None
    if stamp is not None:
        stamp = (stamp.replace(tzinfo=UTC) if stamp.tzinfo is None else stamp.astimezone(UTC)).isoformat(
            timespec="microseconds"
        )
    value = [
        str(user.id),
        episode_id,
        position.episode_id if position else None,
        stamp,
        position.position_seconds if position else 0.0,
        bool(position and position.completed),
        bool(position and position.dismissed),
        position.content_id if position else None,
    ]
    return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()


async def _position_to_write(session: AsyncSession, user: User, episode_id: int) -> PlaybackPosition:
    await lock_user(session, user.id)
    # A new copy inherits the most recently saved state of its siblings.
    # Writes stay on the actual item; reads resolve the current group, so a
    # later import immediately inherits state without an ingest-time fanout.
    effective = (await positions_for(session, user, [episode_id])).get(episode_id)
    selected = await session.get(SavedArticle, (user.id, episode_id))
    position = await session.get(PlaybackPosition, (user.id, episode_id), populate_existing=True)
    if position is None:
        position = PlaybackPosition(user_id=user.id, episode_id=episode_id)
        session.add(position)
    if selected is not None:
        position.content_id = selected.content_id
    if effective is not None:
        position.position_seconds = effective.position_seconds
        position.completed = effective.completed
        position.dismissed = effective.dismissed
        position.article_text_version = effective.article_text_version
        position.article_offset_utf16 = effective.article_offset_utf16
    else:
        position.position_seconds = 0.0
        position.completed = False
        position.dismissed = False
        position.article_text_version = None
        position.article_offset_utf16 = None
    return position


async def upsert_position(
    session: AsyncSession,
    user: User,
    episode_id: int,
    position_seconds: float,
    completed: bool,
    *,
    content_id: int | None = None,
    commit: bool = True,
) -> PlaybackPosition:
    # The user lock serializes this with filing and guarded progress requests.
    position = await _position_to_write(session, user, episode_id)
    position.content_id = content_id
    position.position_seconds = position_seconds
    # An older client's newer clock supersedes the previous text bookmark.
    position.article_text_version = None
    position.article_offset_utf16 = None
    position.completed = completed
    position.updated_at = utcnow()
    if commit:
        await session.commit()
    else:
        await session.flush()
    return position


async def set_episode_state(
    session: AsyncSession,
    user: User,
    episode_id: int,
    *,
    played: bool | None = None,
    dismissed: bool | None = None,
    commit: bool = True,
) -> PlaybackPosition:
    """File an episode: heard, put aside, or back in the list.

    Both flags are optional and only what is given is touched, so hiding an
    episode does not quietly claim she listened to it and vice versa. Kept
    apart from `upsert_position` because that one runs from a heartbeat every
    thirty seconds and must never be the thing that decides these.
    """
    position = await _position_to_write(session, user, episode_id)
    if played is not None:
        position.completed = played
        if not played:
            # "I have not heard that" means start it again, not resume its last
            # thirty seconds — which is what an untouched position would do,
            # and which the app would still describe as finished.
            position.position_seconds = 0.0
            position.article_text_version = None
            position.article_offset_utf16 = None
    if dismissed is not None:
        position.dismissed = dismissed
    position.updated_at = utcnow()
    if commit:
        await session.commit()
    else:
        await session.flush()
    return position


def filed_away(user: User):
    """The episodes to keep out of her feed: heard, or asked not to see again.

    A select rather than a list of ids, so it goes into the feed query as a
    subquery and the database does the excluding.
    """
    return select(PlaybackPosition.episode_id).where(
        PlaybackPosition.user_id == user.id,
        or_(PlaybackPosition.completed, PlaybackPosition.dismissed),
    )


async def positions_for(session: AsyncSession, user: User, episode_ids: Iterable[int]) -> dict[int, PlaybackPosition]:
    ids = list(episode_ids)
    if not ids:
        return {}
    group = await groups.catalog(session, user.id)
    expanded = {copy for item_id in ids for copy in group.equivalents(item_id)}
    positions = list(
        await session.scalars(
            select(PlaybackPosition)
            .where(PlaybackPosition.user_id == user.id, PlaybackPosition.episode_id.in_(expanded))
            .order_by(PlaybackPosition.updated_at.desc(), PlaybackPosition.episode_id.desc())
            .execution_options(populate_existing=True)
        )
    )
    by_id = {position.episode_id: position for position in positions}
    order = {position.episode_id: index for index, position in enumerate(positions)}
    result = {}
    pinned = set(
        await session.scalars(
            select(SavedArticle.episode_id).where(
                SavedArticle.user_id == user.id, SavedArticle.episode_id.in_(ids), SavedArticle.content_id.is_not(None)
            )
        )
    )
    for item_id in ids:
        if item_id in pinned:
            if item_id in by_id:
                result[item_id] = by_id[item_id]
            continue
        candidates = [by_id[copy] for copy in group.equivalents(item_id) if copy in by_id]
        if candidates:
            # The database orders timestamps consistently even when SQLite
            # returns naive datetimes beside freshly written aware ones.
            result[item_id] = min(candidates, key=lambda p: order[p.episode_id])
    return result


async def grouped_filed_ids(session: AsyncSession, user: User, group: groups.Catalog) -> list[int]:
    stored = await positions_for(session, user, group.copies)
    return [item_id for item_id, position in stored.items() if position.completed or position.dismissed]
