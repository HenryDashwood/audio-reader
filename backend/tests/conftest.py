import contextlib
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from audioreader.auth.dependencies import get_current_user
from audioreader.db import get_session
from audioreader.feeds import fetcher
from audioreader.llm.fake import FakeLLMClient
from audioreader.llm.provider import get_discovery_llm_client, get_llm_client
from audioreader.main import create_app
from audioreader.models import Base, User, utcnow
from audioreader.routers.auth import AI_DATA_SHARING_CONSENT_VERSION

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture(autouse=True)
def public_test_dns(monkeypatch):
    """HTTP mocks use reserved .test/.example hosts, which intentionally have no DNS."""

    async def resolve(_host: str, _port: int) -> set[str]:
        return {"93.184.216.34"}

    monkeypatch.setattr(fetcher, "resolve_host_addresses", resolve)


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
def fake_llm() -> FakeLLMClient:
    return FakeLLMClient()


@pytest.fixture
async def user(session: AsyncSession) -> User:
    # Most API tests exercise the product after onboarding. Consent itself has
    # focused auth/command tests; keeping the shared fixture opted in avoids
    # every unrelated command test becoming a consent setup test.
    user = User(
        display_name="Test User",
        ai_consent_version=AI_DATA_SHARING_CONSENT_VERSION,
        ai_data_sharing_consented_at=utcnow(),
    )
    session.add(user)
    await session.commit()
    return user


@pytest.fixture
async def client(session: AsyncSession, fake_llm: FakeLLMClient, user: User) -> AsyncIterator[AsyncClient]:
    # Auth is overridden with a fixed user: API tests exercise behaviour, not
    # token verification, which has its own tests in test_auth_api.py.
    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[get_llm_client] = lambda: fake_llm
    app.dependency_overrides[get_discovery_llm_client] = lambda: fake_llm
    app.dependency_overrides[get_current_user] = lambda: user
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


@pytest.fixture
def make_client(session: AsyncSession, fake_llm: FakeLLMClient):
    """Factory for a client authenticated as a specific user, for tests that
    need two users against the same database."""

    @contextlib.asynccontextmanager
    async def factory(as_user: User) -> AsyncIterator[AsyncClient]:
        app = create_app()
        app.dependency_overrides[get_session] = lambda: session
        app.dependency_overrides[get_llm_client] = lambda: fake_llm
        app.dependency_overrides[get_discovery_llm_client] = lambda: fake_llm
        app.dependency_overrides[get_current_user] = lambda: as_user
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client

    return factory


@pytest.fixture
def podcast_xml() -> bytes:
    return (FIXTURES / "podcast_feed.xml").read_bytes()


@pytest.fixture
def article_xml() -> bytes:
    return (FIXTURES / "article_feed.xml").read_bytes()
