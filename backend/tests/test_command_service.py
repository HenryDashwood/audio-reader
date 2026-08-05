import pytest

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.client import LLMError
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed

FEED_URL = "https://example.com/feed.xml"


@pytest.fixture
async def library(session):
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
    await session.commit()
    return feed


class TestCandidates:
    async def test_includes_feed_title_and_clean_description(self, session, library):
        candidates = await service.build_candidates(session)
        assert candidates[0].feed_title == "The History Hour"
        # HTML must be stripped before it reaches the model.
        assert candidates[0].description == "With guests Adam Zamoyski and Kate Williams on 1815."

    async def test_newest_first(self, session, library):
        candidates = await service.build_candidates(session)
        assert [c.title for c in candidates] == [
            "The Congress of Vienna",
            "The Fall of Constantinople",
        ]

    async def test_respects_limit(self, session, library):
        assert len(await service.build_candidates(session, limit=1)) == 1


class TestInterpret:
    async def test_play_episode_returns_playable_audio(self, session, library):
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, transcript="play the one about Vienna")

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.audio_url == "https://cdn.example.com/104.mp3"

    async def test_spoken_response_confirms_the_choice(self, session, library):
        llm = FakeLLMClient(
            {
                "action": "play_episode",
                "episode_id": 1,
                "spoken_response": "Playing The Congress of Vienna.",
            }
        )
        result = await service.interpret(session, llm, transcript="play the Vienna one")
        assert result.spoken_response == "Playing The Congress of Vienna."

    async def test_prompt_contains_transcript_and_candidates(self, session, library):
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "Sorry?"})
        await service.interpret(session, llm, transcript="play the Vienna one")

        prompt = llm.calls[0]["user"]
        assert "play the Vienna one" in prompt
        assert "The Congress of Vienna" in prompt

    async def test_unknown_action_passes_through(self, session, library):
        llm = FakeLLMClient(
            {"action": "unknown", "spoken_response": "I did not catch which episode."}
        )
        result = await service.interpret(session, llm, transcript="mumble mumble")

        assert result.action == Action.UNKNOWN
        assert result.episode is None

    async def test_hallucinated_episode_id_is_rejected(self, session, library):
        # The model must never be trusted to invent primary keys.
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 999, "spoken_response": "ok"})
        result = await service.interpret(session, llm, transcript="play something")

        assert result.action == Action.UNKNOWN
        assert result.episode is None

    async def test_malformed_model_output_is_rejected(self, session, library):
        llm = FakeLLMClient({"action": "explode the phone"})
        result = await service.interpret(session, llm, transcript="play something")
        assert result.action == Action.UNKNOWN

    async def test_llm_failure_raises(self, session, library):
        llm = FakeLLMClient(error=LLMError("upstream down"))
        with pytest.raises(LLMError):
            await service.interpret(session, llm, transcript="play something")

    async def test_empty_library_short_circuits_without_calling_llm(self, session):
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, transcript="play something")

        assert result.action == Action.UNKNOWN
        assert llm.calls == []

    async def test_articles_are_not_offered_as_playable(self, session):
        feed = Feed(url="https://blog.example.com/feed", title="Notes on Progress")
        feed.episodes = [Episode(guid="a1", title="Why sewers made cities possible")]
        session.add(feed)
        await session.commit()

        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, transcript="play the sewers one")

        # No audio to play yet: article text-to-speech is a later increment.
        assert result.action == Action.UNKNOWN
