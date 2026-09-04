"""Playback positions: PUT upsert plus read-back embedded in episode payloads."""

from datetime import UTC, datetime

import pytest

from audioreader.models import Episode, Feed, Subscription, User

FEED_URL = "https://example.com/feed.xml"


@pytest.fixture
async def episode(session, user):
    feed = Feed(url=FEED_URL, title="The History Hour")
    feed.episodes = [
        Episode(
            guid="ep-104",
            title="The Congress of Vienna",
            audio_url="https://cdn.example.com/104.mp3",
            duration_seconds=2700,
            published_at=datetime(2026, 8, 4, tzinfo=UTC),
        )
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed.episodes[0]


class TestPutPosition:
    async def test_creates_a_position(self, client, episode):
        response = await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 125.5})
        assert response.status_code == 204

        body = (await client.get(f"/episodes/{episode.id}")).json()
        assert body["position_seconds"] == 125.5
        assert body["completed"] is False

    async def test_last_write_wins(self, client, episode):
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 100})
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 50})

        body = (await client.get(f"/episodes/{episode.id}")).json()
        assert body["position_seconds"] == 50

    async def test_completed_round_trips(self, client, episode):
        await client.put(
            f"/episodes/{episode.id}/position",
            json={"position_seconds": 2650, "completed": True},
        )
        assert (await client.get(f"/episodes/{episode.id}")).json()["completed"] is True

    async def test_a_measured_duration_replaces_the_feeds_claim(self, client, episode):
        # The feed said 45 minutes; the player, having loaded the audio, knows
        # better. Without this, "minutes left" in a list is worked out from the
        # claim while the player counts down the real thing.
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 100, "duration_seconds": 3010})

        assert (await client.get(f"/episodes/{episode.id}")).json()["duration_seconds"] == 3010

    async def test_an_omitted_duration_leaves_the_feeds_claim(self, client, episode):
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 100})

        assert (await client.get(f"/episodes/{episode.id}")).json()["duration_seconds"] == 2700

    async def test_a_nonsense_duration_is_dropped(self, client, episode):
        # Fired from a background heartbeat that never reads the answer, so
        # junk is ignored rather than rejected with a 422 nobody sees.
        response = await client.put(
            f"/episodes/{episode.id}/position", json={"position_seconds": 100, "duration_seconds": 0}
        )
        assert response.status_code == 204

        assert (await client.get(f"/episodes/{episode.id}")).json()["duration_seconds"] == 2700

    async def test_unknown_episode_is_404(self, client):
        response = await client.put("/episodes/9999/position", json={"position_seconds": 10})
        assert response.status_code == 404

    async def test_negative_position_is_clamped(self, client, episode):
        # Scrubbers can briefly report negative time; the app fires these in
        # the background and never sees an error, so clamp rather than 422.
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": -3})
        assert (await client.get(f"/episodes/{episode.id}")).json()["position_seconds"] == 0


class TestPositionReadback:
    async def test_never_played_episode_has_null_position(self, client, episode):
        body = (await client.get(f"/episodes/{episode.id}")).json()
        assert body["position_seconds"] is None
        assert body["completed"] is False

    async def test_embedded_in_recent_episodes(self, client, episode):
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 42})
        body = (await client.get("/episodes")).json()
        assert body[0]["position_seconds"] == 42

    async def test_embedded_in_feed_episodes(self, client, episode):
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 42})
        body = (await client.get(f"/feeds/{episode.feed_id}/episodes")).json()
        assert body[0]["position_seconds"] == 42

    async def test_positions_are_private_to_the_user(self, client, episode, session, make_client):
        await client.put(f"/episodes/{episode.id}/position", json={"position_seconds": 42})

        other = User(display_name="Other")
        session.add(other)
        await session.flush()
        session.add(Subscription(user_id=other.id, feed_id=episode.feed_id))
        await session.commit()

        async with make_client(other) as other_client:
            body = (await other_client.get(f"/episodes/{episode.id}")).json()
        assert body["position_seconds"] is None
