from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import Base

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
async def session() -> AsyncIterator[AsyncSession]:
    # Each test gets a fresh in-memory database: full isolation, no cleanup.
    engine = create_async_engine("sqlite+aiosqlite://")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as session:
        yield session
    await engine.dispose()


@pytest.fixture
async def client(session: AsyncSession) -> AsyncIterator[AsyncClient]:
    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


@pytest.fixture
def podcast_xml() -> bytes:
    return (FIXTURES / "podcast_feed.xml").read_bytes()


@pytest.fixture
def article_xml() -> bytes:
    return (FIXTURES / "article_feed.xml").read_bytes()
