from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from audioreader.config import settings

engine = create_async_engine(settings.database_url)
SessionMaker = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency: one session (and one transaction scope) per request."""
    async with SessionMaker() as session:
        yield session
