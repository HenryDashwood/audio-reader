import pytest

from audioreader.commands import service
from audioreader.commands.intents import Action, Speaker, Turn
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

    async def test_nothing_is_added_when_every_word_matches_everything(self, session, user, deep_archive):
        # "weekly" is in all two hundred descriptions, exactly as "time" is in
        # a third of In Our Time's. Searching for it would fill the spare
        # slots — and about a thousand input tokens — with whatever mentioned
        # it most recently. Better to leave them empty.
        offered = await service.build_candidates(session, user, "play the weekly programme", limit=60)
        assert len(offered) == 60

    async def test_a_word_is_not_matched_inside_a_longer_one(self, session, user, deep_archive):
        # Reported from real use: "In Our Time" was mis-transcribed as "in our
        # stand", and "stand" as a bare substring matched 173 In Our Time
        # episodes — 129 of them merely saying "understanding". Fifteen
        # candidate slots and the tokens to describe them, all noise.
        from audioreader.models import Episode

        session.add(
            Episode(
                feed_id=deep_archive.id,
                guid="understanding",
                title="Consciousness",
                description="What it means to understand understanding.",
                audio_url="https://cdn.example.com/u.mp3",
            )
        )
        await session.commit()

        offered = await service.build_candidates(session, user, "play the stand one", limit=5)
        assert "Consciousness" not in {candidate.title for candidate in offered}

    async def test_a_word_still_matches_its_own_inflections(self, session, user, deep_archive):
        # The other half of the trade: English inflects at the end, so a
        # prefix must still match. Losing "volcanoes" for "volcano" would be
        # a worse bug than the one above.
        from audioreader.models import Episode

        session.add(
            Episode(
                feed_id=deep_archive.id,
                guid="volcanoes",
                title="Volcanoes",
                description="Lava, and where it comes from.",
                audio_url="https://cdn.example.com/v.mp3",
            )
        )
        await session.commit()

        offered = await service.build_candidates(session, user, "play the volcano one", limit=5)
        assert "Volcanoes" in {candidate.title for candidate in offered}

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


class TestConversation:
    """A request that takes more than one sentence.

    Before this, the app could ask which episode she meant and then read her
    answer as though she had walked up and said it — so every clarification was
    a question the pipeline could not use the answer to.
    """

    def _turns(self):
        return [
            Turn(speaker=Speaker.HER, text="play the history hour"),
            Turn(speaker=Speaker.APP, text="Which episode?"),
        ]

    async def test_what_was_said_reaches_the_model(self, session, user, library):
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        await service.interpret(session, llm, user=user, transcript="the Vienna one", turns=self._turns())

        prompt = llm.calls[0]["user"]
        assert "play the history hour" in prompt
        assert "Which episode?" in prompt

    async def test_her_latest_sentence_comes_last(self, session, user, library):
        # The request should be the line nearest the list it is answered from.
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "Sorry?"})
        await service.interpret(session, llm, user=user, transcript="the Vienna one", turns=self._turns())

        prompt = llm.calls[0]["user"]
        assert prompt.index("Which episode?") < prompt.index("the Vienna one")

    async def test_each_side_is_attributed(self, session, user, library):
        # "You said" and "She said", so the model can tell its own question
        # from her answer to it — which is the whole basis for combining them.
        prompt = service.build_prompt("the Vienna one", [], turns=self._turns())
        assert 'She said: "play the history hour"' in prompt
        assert 'You said: "Which episode?"' in prompt

    async def test_a_fresh_request_says_nothing_about_an_exchange(self, session, user, library):
        prompt = service.build_prompt("play something", [])
        assert "exchange" not in prompt
        assert prompt.count("She said") == 1

    async def test_the_search_reads_every_word_she_said(self, session, user, deep_archive):
        # The point of the whole thing: "the one about Athelstan" narrows the
        # library, "the In Our Time one" does not, and after a clarification
        # only one of them is in the latest sentence. Searched apart, the
        # episode stays outside the candidate window and the answer she just
        # gave cannot be acted on.
        said = service.spoken_so_far(
            "the one about Athelstan",
            [Turn(speaker=Speaker.HER, text="play something from the archive")],
        )
        offered = await service.build_candidates(session, user, said, limit=60)
        assert "Æthelstan" in {candidate.title for candidate in offered}

    async def test_our_own_questions_are_not_searched_for(self, session, user, library):
        # They are our words, not hers, and searching them spends the
        # back-catalogue slots on whatever last mentioned "episode".
        said = service.spoken_so_far("the Vienna one", self._turns())
        assert "Which episode?" not in said
        assert said == "the Vienna one play the history hour"

    async def test_the_word_she_just_said_is_searched_for_first(self, session, user, deep_archive):
        # Only the first few identifying words are looked up. In the order it
        # was spoken, a wordy opening line spends the whole budget and the one
        # word naming the episode — the word she has only just said — is
        # dropped, so the clarification cannot be acted on.
        rambling = Turn(
            speaker=Speaker.HER,
            text="I wanted something about the Byzantine Empire, Constantinople, "
            "Justinian, mosaics and the Hagia Sophia cathedral",
        )
        said = service.spoken_so_far("the Athelstan one", [rambling, Turn(speaker=Speaker.APP, text="Which one?")])

        assert "athelstan" in service.spoken_keywords(said)
        offered = await service.build_candidates(session, user, said, limit=60)
        assert "Æthelstan" in {candidate.title for candidate in offered}


class TestExpectsReply:
    """Whether the app should listen again, which the action cannot say.

    "Which show did you mean?" and "You are already subscribed to that" are
    both `unknown`, and she has to answer one and not the other.
    """

    async def test_a_question_from_the_model_expects_an_answer(self, session, user, library):
        llm = FakeLLMClient({"action": "unknown", "spoken_response": "Which episode did you mean?"})
        result = await service.interpret(session, llm, user=user, transcript="play that one")
        assert result.expects_reply

    async def test_a_played_episode_does_not(self, session, user, library):
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play the Vienna one")
        assert not result.expects_reply

    async def test_an_invented_episode_id_asks_again(self, session, user, library):
        # She said something perfectly answerable and the model fumbled the id.
        # Falling silent here strands a question she can hear.
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 999, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play something")
        assert result.expects_reply

    async def test_an_empty_library_is_not_a_question(self, session, user):
        # "Say subscribe, and the name of a show" is instructions, not a
        # question — and opening the microphone on it would be a tone she has
        # no reason to expect, followed by an apology for hearing nothing.
        llm = FakeLLMClient({"action": "play_episode", "episode_id": 1, "spoken_response": "ok"})
        result = await service.interpret(session, llm, user=user, transcript="play something")

        assert result.action == Action.UNKNOWN
        assert not result.expects_reply

    async def test_an_unusable_speed_asks_which_one(self, session, user, library):
        llm = FakeLLMClient({"action": "set_speed", "speed": 42, "spoken_response": ""})
        result = await service.interpret(session, llm, user=user, transcript="play it at warp speed")
        assert result.expects_reply

    async def test_a_valid_speed_does_not(self, session, user, library):
        llm = FakeLLMClient({"action": "set_speed", "speed": 1.5, "spoken_response": ""})
        result = await service.interpret(session, llm, user=user, transcript="one and a half speed")
        assert not result.expects_reply
