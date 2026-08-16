"""Per-user playback positions: one row per (user, episode), last write wins.

Also where an episode is filed: heard, put aside, or back in the list.
"""

from collections.abc import Iterable

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import PlaybackPosition, User, utcnow


async def upsert_position(
    session: AsyncSession,
    user: User,
    episode_id: int,
    position_seconds: float,
    completed: bool,
) -> PlaybackPosition:
    # get-then-set rather than dialect-specific ON CONFLICT: it works on both
    # Postgres and the SQLite test database, and the only writer for a row is
    # the row's own user, so the race window does not matter in practice.
    position = await session.get(PlaybackPosition, (user.id, episode_id))
    if position is None:
        position = PlaybackPosition(user_id=user.id, episode_id=episode_id)
        session.add(position)
    position.position_seconds = position_seconds
    position.completed = completed
    position.updated_at = utcnow()
    await session.commit()
    return position


async def set_episode_state(
    session: AsyncSession,
    user: User,
    episode_id: int,
    *,
    played: bool | None = None,
    dismissed: bool | None = None,
) -> PlaybackPosition:
    """File an episode: heard, put aside, or back in the list.

    Both flags are optional and only what is given is touched, so hiding an
    episode does not quietly claim she listened to it and vice versa. Kept
    apart from `upsert_position` because that one runs from a heartbeat every
    thirty seconds and must never be the thing that decides these.
    """
    position = await session.get(PlaybackPosition, (user.id, episode_id))
    if position is None:
        position = PlaybackPosition(user_id=user.id, episode_id=episode_id, position_seconds=0.0)
        session.add(position)
    if played is not None:
        position.completed = played
        if not played:
            # "I have not heard that" means start it again, not resume its last
            # thirty seconds — which is what an untouched position would do,
            # and which the app would still describe as finished.
            position.position_seconds = 0.0
    if dismissed is not None:
        position.dismissed = dismissed
    position.updated_at = utcnow()
    await session.commit()
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
    positions = await session.scalars(
        select(PlaybackPosition).where(PlaybackPosition.user_id == user.id, PlaybackPosition.episode_id.in_(ids))
    )
    return {position.episode_id: position for position in positions}
