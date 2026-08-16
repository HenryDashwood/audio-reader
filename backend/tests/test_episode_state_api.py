"""Filing episodes: played, put aside, and back again — and what the feed shows."""

from datetime import UTC, datetime

import pytest

from audioreader.models import Episode, Feed, Subscription

FEED_URL = "https://example.com/feed.xml"


@pytest.fixture
async def episodes(session, user):
    feed = Feed(url=FEED_URL, title="The History Hour")
    feed.episodes = [
        Episode(
            guid=f"ep-{number}",
            title=f"Episode {number}",
            audio_url=f"https://cdn.example.com/{number}.mp3",
            duration_seconds=2700,
            published_at=datetime(2026, 8, number, tzinfo=UTC),
        )
        for number in (1, 2, 3)
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed.episodes


async def feed_titles(client) -> list[str]:
    return [episode["title"] for episode in (await client.get("/episodes")).json()]


class TestPutState:
    async def test_marks_an_episode_played(self, client, episodes):
        response = await client.put(f"/episodes/{episodes[0].id}/state", json={"played": True})
        assert response.status_code == 204

        body = (await client.get(f"/episodes/{episodes[0].id}")).json()
        assert body["completed"] is True
        assert body["dismissed"] is False

    async def test_dismissing_does_not_claim_she_heard_it(self, client, episodes):
        # The whole reason the two flags are separate: an episode she skipped
        # must never be reported back as one she listened to.
        await client.put(f"/episodes/{episodes[0].id}/state", json={"dismissed": True})

        body = (await client.get(f"/episodes/{episodes[0].id}")).json()
        assert body["dismissed"] is True
        assert body["completed"] is False

    async def test_omitted_fields_are_left_alone(self, client, episodes):
        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": True})
        await client.put(f"/episodes/{episodes[0].id}/state", json={"dismissed": True})

        body = (await client.get(f"/episodes/{episodes[0].id}")).json()
        assert body["completed"] is True
        assert body["dismissed"] is True

    async def test_unmarking_played_rewinds_it(self, client, episodes):
        # "I have not heard that" means start it again. Left where it was, the
        # app would still describe an episode stopped near the end as finished.
        await client.put(f"/episodes/{episodes[0].id}/position", json={"position_seconds": 2680, "completed": True})

        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": False})

        body = (await client.get(f"/episodes/{episodes[0].id}")).json()
        assert body["completed"] is False
        assert body["position_seconds"] == 0

    async def test_a_heartbeat_does_not_undo_a_dismissal(self, client, episodes):
        # Position reports keep arriving for whatever is playing; they write
        # position and completed, and must not touch this.
        await client.put(f"/episodes/{episodes[0].id}/state", json={"dismissed": True})

        await client.put(f"/episodes/{episodes[0].id}/position", json={"position_seconds": 30})

        assert (await client.get(f"/episodes/{episodes[0].id}")).json()["dismissed"] is True

    async def test_unknown_episode_is_404(self, client):
        response = await client.put("/episodes/9999/state", json={"played": True})
        assert response.status_code == 404


class TestFeedExcludesFiledEpisodes:
    async def test_played_episodes_leave_the_feed(self, client, episodes):
        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": True})

        assert episodes[0].title not in await feed_titles(client)

    async def test_dismissed_episodes_leave_the_feed(self, client, episodes):
        await client.put(f"/episodes/{episodes[1].id}/state", json={"dismissed": True})

        assert episodes[1].title not in await feed_titles(client)

    async def test_the_rest_stay(self, client, episodes):
        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": True})

        assert len(await feed_titles(client)) == 2

    async def test_restoring_brings_it_back(self, client, episodes):
        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": True})
        await client.put(f"/episodes/{episodes[0].id}/state", json={"played": False, "dismissed": False})

        assert episodes[0].title in await feed_titles(client)

    async def test_a_part_heard_episode_stays(self, client, episodes):
        # Continue listening depends on this: an episode she is halfway
        # through is exactly the one the feed most needs to keep offering.
        await client.put(f"/episodes/{episodes[0].id}/position", json={"position_seconds": 600})

        assert episodes[0].title in await feed_titles(client)

    async def test_the_show_page_still_has_it(self, client, episodes):
        # Filing something away takes it out of the "what's new" list, not out
        # of her library — otherwise a mistake is unrecoverable by touch.
        await client.put(f"/episodes/{episodes[0].id}/state", json={"dismissed": True})

        listed = (await client.get(f"/feeds/{episodes[0].feed_id}/episodes")).json()
        assert episodes[0].title in [episode["title"] for episode in listed]
