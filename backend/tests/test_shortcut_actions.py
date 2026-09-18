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


async def test_offline_filing_receipt_and_targeted_undo_preserve_position(client, item):
    await client.put(f"/episodes/{item.id}/position", json={"position_seconds": 123, "completed": False})
    body = {"action": "restore", "episode_id": item.id, "request_id": "offline-one"}
    first = await client.post("/actions/offline", json=body)
    assert first.status_code == 200, first.text
    assert (await client.post("/actions/offline", json=body)).json() == first.json()
    inverse = {"action": "undo", "episode_id": item.id, "request_id": "offline-undo", "undo_request_id": "offline-one"}
    result = await client.post("/actions/offline", json=inverse)
    assert result.status_code == 200, result.text
    assert result.json()["episode"]["position_seconds"] == 123
    assert (await client.post("/actions/offline", json=inverse)).json() == result.json()


async def test_offline_undo_cannot_undo_a_later_action_from_another_device(client, item):
    await client.post(
        "/actions/offline", json={"action": "dismiss", "episode_id": item.id, "request_id": "old-device"}
    )
    await client.post("/actions", json={"action": "mark_played", "episode_id": item.id, "request_id": "new-device"})
    result = await client.post(
        "/actions/offline",
        json={
            "action": "undo",
            "episode_id": item.id,
            "request_id": "late-undo",
            "undo_request_id": "old-device",
        },
    )
    assert result.status_code == 200
    assert result.json()["action"] == "unknown"
    current = (await client.get(f"/episodes/{item.id}")).json()
    assert current["completed"] is True
    assert current["dismissed"] is True


async def test_offline_filing_supports_owned_standalone_saved_content_and_rejects_old_versions(client):
    html = (
        "<article><h1>Private article</h1>"
        + "<p>Useful private saved article words and examples.</p>" * 30
        + "</article>"
    )
    response = await client.post("/saved", json={"url": "https://example.test/private-article", "html": html})
    assert response.status_code == 200, response.text
    item = response.json()
    body = {
        "action": "mark_played",
        "episode_id": item["id"],
        "content_id": item["content_id"],
        "request_id": "saved-offline",
    }
    result = await client.post("/actions/offline", json=body)
    assert result.status_code == 200, result.text
    assert result.json()["episode"]["completed"] is True
    stale = await client.post(
        "/actions/offline", json={**body, "request_id": "stale-offline", "content_id": item["content_id"] + 1}
    )
    assert stale.status_code == 409
    assert (await client.get(f"/episodes/{item['id']}")).json()["completed"] is True


async def test_offline_actions_require_an_undo_target_and_library_membership(client, session):
    assert (
        await client.post("/actions/offline", json={"action": "undo", "request_id": "untargeted"})
    ).status_code == 422
    feed = Feed(url="https://example.test/unfollowed", title="Unfollowed")
    episode = Episode(feed=feed, guid="unfollowed", title="Unfollowed item")
    session.add(episode)
    await session.commit()
    response = await client.post(
        "/actions/offline", json={"action": "dismiss", "episode_id": episode.id, "request_id": "not-owned"}
    )
    assert response.status_code == 409
