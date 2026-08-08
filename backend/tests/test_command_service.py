import pytest

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.client import LLMError
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed, Subscription

FEED_URL = "https://example.com/feed.xml"


@pytest.fixture
async def library(session, user):
    """Two feeds with episodes, resembling what the poller would have stored."""
    from datetime import UTC, datetime

    feed = Feed(url=FEED_URL, title="The History Hour")
    feed.episodes = [
        Episode(
            guid="ep-104",
            title="The Congress of Vienna",
            description="<p>With guests Adam Zamoyski and Kate Williams on 1815.</p>",
            audio_url="https://cdn.example.com/104.mp3",
            duration_seconds=2700,
            published_at=datetime(2026, 8, 4, tzinfo=UTC),
        ),
        Episode(
            guid="ep-103",
            title="The Fall of Constantinople",
            description="<p>With guest Professor Maria Sharpe on the siege of 1453.</p>",
            audio_url="https://cdn.example.com/103.mp3",
            duration_seconds=3723,
            published_at=datetime(2026, 7, 28, tzinfo=UTC),
        ),
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed


class TestCandidates:
    async def test_includes_feed_title_and_clean_description(self, session, user, library):
        candidates = await service.build_candidates(session, user)
        assert candidates[0].feed_title == "The History Hour"
        # HTML must be stripped before it reaches the model.
        assert candidates[0].description == "With guests Adam Zamoyski and Kate Williams on 1815."

    async def test_newest_first(self, session, user, library):
        candidates = await service.build_candidates(session, user)
        assert [c.title for c in candidates] == [
            "The Congress of Vienna",
            "The Fall of Constantinople",
        ]

    async def test_respects_limit(self, session, user, library):
        assert len(await service.build_candidates(session, user, limit=1)) == 1


class TestInterpret:
    async def test_play_episode_returns_playable_audio(self, session, user, library):
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(
            session, llm, user=user, transcript="play the one about Vienna"
        )

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.audio_url == "https://cdn.example.com/104.mp3"

    async def test_spoken_response_confirms_the_choice(self, session, user, library):
        llm = FakeLLMClient(
            {
                "action": "play_episode",
                "episode_id": 1,
                "spoken_response": "Playing The Congress of Vienna.",
            }
        )
        result = await service.interpret(session, llm, user=user, transcript="play the Vienna one")
        assert result.spoken_response == "Playing The Congress of Vienna."

    async def test_prompt_contains_transcript_and_candidates(self, session, user, library):
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "Sorry?"})
        await service.interpret(session, llm, user=user, transcript="play the Vienna one")

        prompt = llm.calls[0]["user"]
        assert "play the Vienna one" in prompt
        assert "The Congress of Vienna" in prompt

    async def test_unknown_action_passes_through(self, session, user, library):
        llm = FakeLLMClient(
            {"action": "unknown", "spoken_response": "I did not catch which episode."}
        )
        result = await service.interpret(session, llm, user=user, transcript="mumble mumble")

        assert result.action == Action.UNKNOWN
        assert result.episode is None

    async def test_hallucinated_episode_id_is_rejected(self, session, user, library):
        # The model must never be trusted to invent primary keys.
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 999, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play something")

        assert result.action == Action.UNKNOWN
        assert result.episode is None

    async def test_malformed_model_output_is_rejected(self, session, user, library):
        llm = FakeLLMClient({"action": "explode the phone"})
        result = await service.interpret(session, llm, user=user, transcript="play something")
        assert result.action == Action.UNKNOWN

    async def test_llm_failure_raises(self, session, user, library):
        llm = FakeLLMClient(error=LLMError("upstream down"))
        with pytest.raises(LLMError):
            await service.interpret(session, llm, user=user, transcript="play something")

    async def test_empty_library_still_reaches_the_model(self, session, user):
        # An empty library is exactly when she would say "subscribe to X", so
        # short-circuiting here would make a fresh install impossible to use.
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play something")

        assert llm.calls != []
        assert result.action == Action.UNKNOWN
        assert "subscribe" in result.spoken_response.lower()

    async def test_articles_are_not_offered_as_playable(self, session, user):
        feed = Feed(url="https://blog.example.com/feed", title="Notes on Progress")
        feed.episodes = [Episode(guid="a1", title="Why sewers made cities possible")]
        session.add(feed)
        session.add(Subscription(user_id=user.id, feed=feed))
        await session.commit()

        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play the sewers one")

        # No audio to play yet: article text-to-speech is a later increment.
        assert result.action == Action.UNKNOWN
