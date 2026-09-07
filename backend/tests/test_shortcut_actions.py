"""Typed Shortcuts actions use no model and retain exact, recoverable undo."""

import uuid

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import AsyncAdaptedQueuePool

from audioreader.models import Base, Episode, Feed, Subscription


@pytest.fixture
async def session():
    name = uuid.uuid4().hex
    engine = create_async_engine(
        f"sqlite+aiosqlite:///file:{name}?mode=memory&cache=shared&uri=true",
        poolclass=AsyncAdaptedQueuePool,
    )
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as value:
        yield value
    await engine.dispose()


@pytest.fixture
async def item(session, user):
    feed = Feed(url="https://example.test/feed", title="History")
    episode = Episode(feed=feed, guid="one", title="The first episode", audio_url="https://example.test/one.mp3")
    session.add_all([episode, Subscription(user_id=user.id, feed=feed)])
    await session.commit()
    return episode


async def test_filing_and_undo_preserve_progress_without_ai_consent(client, item, user, session):
    user.ai_consent_version = None
    user.ai_data_sharing_consented_at = None
    await session.commit()
    await client.put(f"/episodes/{item.id}/position", json={"position_seconds": 321, "completed": False})
    filed = await client.post("/actions", json={"action": "restore", "episode_id": item.id, "request_id": "file-one"})
    assert filed.status_code == 200
    assert filed.json()["episode"]["position_seconds"] == 0
    undone = await client.post("/actions", json={"action": "undo", "request_id": "undo-one"})
    assert undone.status_code == 200
    assert undone.json()["episode"]["position_seconds"] == 321
    assert undone.json()["episode"]["completed"] is False


async def test_retry_replays_receipt_instead_of_overwriting_undo(client, item):
    body = {"action": "dismiss", "episode_id": item.id, "request_id": "repeat-file"}
    first = await client.post("/actions", json=body)
    second = await client.post("/actions", json=body)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    undone = await client.post("/actions", json={"action": "undo", "request_id": "undo-repeat"})
    assert undone.json()["episode"]["dismissed"] is False
    repeated_undo = await client.post("/actions", json={"action": "undo", "request_id": "undo-repeat"})
    assert repeated_undo.json() == undone.json()


async def test_conflicting_receipt_does_not_execute_other_action(client, item):
    await client.post("/actions", json={"action": "dismiss", "episode_id": item.id, "request_id": "same"})
    response = await client.post(
        "/actions", json={"action": "mark_played", "episode_id": item.id, "request_id": "same"}
    )
    assert response.status_code == 409
    assert (await client.get(f"/episodes/{item.id}")).json()["completed"] is False


async def test_cannot_file_another_users_private_item(client, session):
    feed = Feed(url="https://example.test/private", title="Private")
    episode = Episode(feed=feed, guid="private", title="Private item")
    session.add(episode)
    await session.commit()
    response = await client.post(
        "/actions", json={"action": "dismiss", "episode_id": episode.id, "request_id": "private"}
    )
    assert response.status_code == 409
    assert "no longer in your library" in response.json()["detail"]["spoken_response"]


@pytest.mark.parametrize(
    "body",
    [
        {"action": "mark_played", "request_id": "missing-item"},
        {"action": "delete_everything", "request_id": "bad-action"},
        {"action": "undo", "request_id": ""},
    ],
)
async def test_invalid_actions_are_rejected(client, body):
    assert (await client.post("/actions", json=body)).status_code == 422
