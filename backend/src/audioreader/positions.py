"""Per-user playback positions: one row per (user, episode), last write wins."""

from collections.abc import Iterable

from sqlalchemy import select
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


async def positions_for(session: AsyncSession, user: User, episode_ids: Iterable[int]) -> dict[int, PlaybackPosition]:
    ids = list(episode_ids)
    if not ids:
        return {}
    positions = await session.scalars(
        select(PlaybackPosition).where(PlaybackPosition.user_id == user.id, PlaybackPosition.episode_id.in_(ids))
    )
    return {position.episode_id: position for position in positions}
