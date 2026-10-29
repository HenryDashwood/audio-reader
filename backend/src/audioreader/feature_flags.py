"""Database-owned targeting. Unknown flags are always disabled."""

from fastapi import HTTPException
from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import FeatureFlag, User, UserFeatureFlag

PDF_UNLIMITED = "pdf_unlimited"


def evaluated_flags(user: User):
    return select(FeatureFlag.key, func.coalesce(UserFeatureFlag.enabled, FeatureFlag.default_enabled)).outerjoin(
        UserFeatureFlag,
        and_(UserFeatureFlag.flag_key == FeatureFlag.key, UserFeatureFlag.user_id == user.id),
    )


async def for_user(session: AsyncSession, user: User) -> dict[str, bool]:
    rows = await session.execute(evaluated_flags(user).order_by(FeatureFlag.key))
    return {key: bool(enabled) for key, enabled in rows}


async def enabled(session: AsyncSession, user: User, key: str) -> bool:
    return bool(
        await session.scalar(
            evaluated_flags(user)
            .with_only_columns(func.coalesce(UserFeatureFlag.enabled, FeatureFlag.default_enabled))
            .where(FeatureFlag.key == key)
        )
    )


async def require_enabled(session: AsyncSession, user: User, key: str) -> None:
    if not await enabled(session, user, key):
        raise HTTPException(403, "This feature is not enabled for this account.")
