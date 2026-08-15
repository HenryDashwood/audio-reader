from datetime import UTC, datetime

import pytest

from audioreader.llm.client import LLMError
from audioreader.models import Episode, Feed, Subscription


@pytest.fixture
async def library(session, user):
    feed = Feed(url="https://example.com/feed.xml", title="The History Hour")
    feed.episodes = [
        Episode(
            guid="ep-104",
            title="The Congress of Vienna",
            description="<p>With guests Adam Zamoyski and Kate Williams.</p>",
            audio_url="https://cdn.example.com/104.mp3",
            duration_seconds=2700,
            published_at=datetime(2026, 8, 4, tzinfo=UTC),
        )
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed


class TestCommandEndpoint:
    async def test_play_request_returns_everything_the_player_needs(self, client, fake_llm, library):
        fake_llm.respond_with(
            {
                "action": "play_episode",
                "episode_id": 1,
                "spoken_response": "Playing The Congress of Vienna.",
            }
        )
        response = await client.post("/command", json={"transcript": "play the Vienna episode"})

        assert response.status_code == 200
        body = response.json()
        assert body["action"] == "play_episode"
        assert body["spoken_response"] == "Playing The Congress of Vienna."
        assert body["episode"]["audio_url"] == "https://cdn.example.com/104.mp3"
        assert body["episode"]["title"] == "The Congress of Vienna"

    async def test_unrecognised_request_is_still_a_200_with_speech(self, client, fake_llm, library):
        # The app must always have something to say; an error tone is not enough.
        fake_llm.respond_with({"action": "unknown", "spoken_response": "I could not find that episode."})
        response = await client.post("/command", json={"transcript": "play the thing"})

        assert response.status_code == 200
        body = response.json()
        assert body["action"] == "unknown"
        assert body["spoken_response"] == "I could not find that episode."
        assert body["episode"] is None

    async def test_blank_transcript_is_rejected(self, client, fake_llm, library):
        response = await client.post("/command", json={"transcript": "   "})
        assert response.status_code == 422

    async def test_llm_outage_returns_speakable_error(self, client, fake_llm, library):
        fake_llm.fail_with(LLMError("upstream timeout"))
        response = await client.post("/command", json={"transcript": "play something"})

        assert response.status_code == 503
        assert response.json()["detail"]["spoken_response"]
