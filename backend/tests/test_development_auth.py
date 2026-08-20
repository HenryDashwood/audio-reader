"""The simulator authentication path is useful locally and impossible in production."""

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.config import Settings, settings
from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import User

TOKEN = "hearful-local-development"


@pytest.fixture
async def development_client(session: AsyncSession, monkeypatch) -> AsyncIterator[AsyncClient]:
    monkeypatch.setattr(settings, "environment", "development")
    monkeypatch.setattr(settings, "development_auth_token", TOKEN)
    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client


async def test_development_token_creates_a_stable_local_user(development_client, session):
    headers = {"Authorization": f"Bearer {TOKEN}"}

    first = await development_client.get("/me", headers=headers)
    second = await development_client.get("/me", headers=headers)

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["id"] == str(service.DEVELOPMENT_USER_ID)
    assert second.json()["id"] == first.json()["id"]
    assert await session.scalar(select(func.count(User.id))) == 1


async def test_other_tokens_are_still_rejected(development_client):
    response = await development_client.get("/me", headers={"Authorization": "Bearer anything-else"})
    assert response.status_code == 401


async def test_development_token_is_ignored_outside_development(development_client, monkeypatch):
    monkeypatch.setattr(settings, "environment", "production")
    response = await development_client.get("/me", headers={"Authorization": f"Bearer {TOKEN}"})
    assert response.status_code == 401


def test_production_configuration_rejects_development_authentication():
    with pytest.raises(ValidationError, match="allowed only in the development environment"):
        Settings.model_validate(
            {
                "AUDIOREADER_ENVIRONMENT": "production",
                "development_auth_token": TOKEN,
            }
        )
