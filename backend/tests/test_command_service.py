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
        result = await service.interpret(session, llm, user=user, transcript="play the one about Vienna")

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
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "I did not catch which episode."})
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


@pytest.fixture
async def deep_archive(session, user):
    """A show with a long back catalogue, as a real feed carries.

    In Our Time's own feed holds over a thousand episodes going back to 1998,
    and the poller stores every one of them — so this is the ordinary case,
    not an extreme one.
    """
    from datetime import UTC, datetime, timedelta

    feed = Feed(url="https://archive.example.com/feed.xml", title="The Long Runner")
    start = datetime(2026, 8, 13, tzinfo=UTC)
    feed.episodes = [
        Episode(
            guid=f"old-{index}",
            title=f"Episode {index}",
            description="A weekly programme.",
            audio_url=f"https://cdn.example.com/{index}.mp3",
            published_at=start - timedelta(weeks=index),
        )
        for index in range(200)
    ]
    # Buried seventy weeks down, well outside any recency window.
    feed.episodes[70].title = "Æthelstan"
    feed.episodes[70].description = "The first king of all England."
    feed.episodes[120].description = "A programme about beekeeping in Sussex."
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed


class TestSpokenKeywords:
    def test_drops_the_words_that_say_what_to_do(self):
        assert service.spoken_keywords("play the one about Athelstan") == ["athelstan"]
        assert service.spoken_keywords("read me the latest post") == []

    def test_drops_short_words_that_match_everything(self):
        # "in", "our" and "of" appear in half of any library.
        assert service.spoken_keywords("play the In Our Time one about sleep") == ["time", "sleep"]

    def test_keeps_a_guest_name(self):
        assert service.spoken_keywords("the one with Patricia Fara") == ["patricia", "fara"]

    def test_is_bounded(self):
        assert len(service.spoken_keywords("alpha bravo charlie delta echo foxtrot golf")) == 6


class TestBackCatalogueIsReachable:
    async def test_an_old_episode_she_names_is_offered(self, session, user, deep_archive):
        # The failure this was written for: she named the episode precisely and
        # it was simply not in the list the model was shown.
        by_recency = await service.build_candidates(session, user, limit=60)
        assert "Æthelstan" not in {candidate.title for candidate in by_recency}

        offered = await service.build_candidates(session, user, "play the one about Athelstan", limit=60)
        assert "Æthelstan" in {candidate.title for candidate in offered}

    async def test_a_description_match_counts_too(self, session, user, deep_archive):
        offered = await service.build_candidates(session, user, "the one about beekeeping", limit=60)
        assert any("beekeeping" in (candidate.description or "") for candidate in offered)

    async def test_the_newest_is_still_first(self, session, user, deep_archive):
        # Otherwise "the latest" would start picking up an old match instead.
        offered = await service.build_candidates(session, user, "play the one about Athelstan", limit=60)
        assert offered[0].title == "Episode 0"

    async def test_nothing_is_searched_when_she_named_nothing(self, session, user, deep_archive):
        offered = await service.build_candidates(session, user, "play the latest", limit=60)
        assert len(offered) == 60

    async def test_the_search_can_be_turned_off(self, session, user, deep_archive):
        offered = await service.build_candidates(
            session, user, "play the one about Athelstan", limit=60, search_limit=0
        )
        assert "Æthelstan" not in {candidate.title for candidate in offered}

    async def test_it_stays_inside_her_own_subscriptions(self, session, user, deep_archive):
        from audioreader.models import User

        stranger = User(display_name="Someone Else")
        session.add(stranger)
        await session.commit()

        offered = await service.build_candidates(session, stranger, "play the one about Athelstan", limit=60)
        assert offered == []

    async def test_a_word_that_matches_everything_is_ignored(self, session, user, deep_archive):
        # The real shape of the reported failure: "In Our Time" put the word
        # "time" into the search, and it matched a third of the show's eleven
        # hundred episodes. Scored equally with the word that names one
        # episode, it buried the answer under whatever matched most recently.
        # Here "weekly" is in every description and plays the same part.
        offered = await service.build_candidates(session, user, "play the weekly one about Athelstan", limit=60)
        assert "Æthelstan" in {candidate.title for candidate in offered}

    async def test_a_common_word_is_still_searched_when_it_is_all_she_gave(self, session, user, deep_archive):
        # Dropping every word would mean searching for nothing, which is
        # worse than searching badly.
        offered = await service.build_candidates(session, user, "play the weekly programme", limit=60)
        assert len(offered) >= 60

    async def test_one_show_is_searched_the_same_way(self, session, user, deep_archive):
        # play_from_show reaches a back catalogue too, subscribed or not.
        offered = await service.feed_candidates(session, deep_archive.id, "the one about Athelstan", limit=60)
        assert "Æthelstan" in {candidate.title for candidate in offered}


class TestPrompt:
    async def test_says_what_day_it_is(self, session, user, library):
        from datetime import date

        candidates = await service.build_candidates(session, user)
        prompt = service.build_prompt("play Tuesday's one", candidates, today=date(2026, 8, 15))
        # Without this, an episode's date has nothing to be measured against
        # and "Tuesday's one" cannot be answered at all.
        assert "Saturday 15 August 2026" in prompt

    async def test_defaults_to_today(self, session, user, library):
        from audioreader.models import utcnow

        prompt = service.build_prompt("play something", [])
        assert utcnow().strftime("%d %B %Y") in prompt


class TestNeverSilent:
    async def test_an_unknown_with_no_words_still_says_something(self, session, user, library):
        # Seen from a real provider: unknown with an empty spoken_response,
        # which reached the app as silence.
        llm = FakeLLMClient({"action": "unknown", "spoken_response": ""})
        result = await service.interpret(session, llm, user=user, transcript="mumble")

        assert result.action == Action.UNKNOWN
        assert result.spoken_response.strip()

    async def test_whitespace_counts_as_nothing_said(self, session, user, library):
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "   "})
        result = await service.interpret(session, llm, user=user, transcript="mumble")
        assert result.spoken_response.strip()
