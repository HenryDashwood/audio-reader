"""The eval harness, checked without spending anything.

The corpus itself needs a real model and is never collected here. What is
checked is everything around it: that the synthetic world is shaped the way
the cases assume, that nothing reaches the network, and that the grader tells
a wrong episode apart from a question.
"""

from dataclasses import replace
from datetime import date

import httpx
import pytest

from audioreader.commands import service
from audioreader.commands.intents import Action, InterpretResult
from audioreader.config import settings
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed, Subscription
from evals import cases as corpus
from evals.grading import Grade, Observed, grade, readable_aloud
from evals.runner import run_case
from evals.world import build_world, seed, stub_world

REFERENCE = date(2026, 8, 13)  # a Thursday, so every weekday case is well defined


@pytest.fixture
def world():
    return build_world(REFERENCE)


class TestWorld:
    def test_every_case_names_a_real_episode(self, world):
        """The cases index the world by title at import; this proves the guids
        they produced still exist, which is what stops a renamed episode from
        turning into a case that can never pass."""
        known = {item.guid for show in world for item in show.items}
        for case in corpus.CASES:
            for guid in (*case.expect.episodes, *case.never):
                assert guid in known, f"{case.id} refers to a missing episode {guid!r}"

    def test_case_ids_are_unique(self):
        ids = [case.id for case in corpus.CASES]
        assert len(ids) == len(set(ids))

    def test_every_case_says_why(self):
        for case in corpus.CASES:
            assert case.why.strip(), f"{case.id} has no reason recorded"

    def test_items_are_newest_first(self, world):
        for show in world:
            published = [item.published_at for item in show.items]
            assert published == sorted(published, reverse=True), show.title

    def test_nothing_is_published_today_or_later(self, world):
        for show in world:
            assert show.items[0].published_at.date() < REFERENCE, show.title

    def test_weekday_shows_publish_on_their_day(self, world):
        by_key = {show.key: show for show in world}
        assert {item.published_at.weekday() for item in by_key["in_our_time"].items} == {3}
        assert {item.published_at.weekday() for item in by_key["rest_is_politics"].items} == {1}

    def test_articles_have_no_audio(self, world):
        acx = next(show for show in world if show.key == "astral_codex_ten")
        assert all(item.is_article for item in acx.items)


class TestSeeding:
    async def test_only_subscribed_shows_are_in_the_library(self, session, user, world):
        await seed(session, user, world)
        candidates = await service.build_candidates(session, user, limit=1000)
        shows = {candidate.feed_title for candidate in candidates}
        assert "In Our Time" in shows
        # She can still ask for it — it is just not in her list.
        assert "The Infinite Monkey Cage" not in shows

    async def test_articles_are_offered_and_marked(self, session, user, world):
        await seed(session, user, world)
        candidates = await service.build_candidates(session, user, limit=1000)
        articles = [candidate for candidate in candidates if candidate.is_article]
        assert articles and all(article.feed_title == "Astral Codex Ten" for article in articles)

    async def test_recency_alone_cannot_reach_the_back_catalogue(self, session, user, world):
        """Why the corpus exists, kept as an assertion.

        The world is crowded on purpose: four subscriptions publishing six
        times a week means the newest sixty items reach back about twelve
        weeks, and Æthelstan is seventy episodes down. No model can pick an
        episode it was never shown.
        """
        await seed(session, user, world)

        offered = await service.build_candidates(session, user)
        assert len(offered) == settings.command_candidate_limit
        assert "Æthelstan" not in {candidate.title for candidate in offered}

    async def test_naming_it_brings_it_within_reach(self, session, user, world):
        # And what fixed it: the words she used are searched across the whole
        # library, so the episode joins the list she is choosing from.
        await seed(session, user, world)

        offered = await service.build_candidates(session, user, "Play the In Our Time episode about Athelstan")
        assert "Æthelstan" in {candidate.title for candidate in offered}
        # Still newest first, so "the latest" keeps meaning the same thing.
        newest = max(
            (show.items[0] for show in world if show.subscribed),
            key=lambda item: item.published_at,
        )
        assert offered[0].title == newest.title


class TestStubbedWorld:
    async def test_the_directory_finds_a_show_by_name(self, world):
        with stub_world(world):
            async with httpx.AsyncClient() as client:
                response = await client.get(
                    "https://itunes.apple.com/search",
                    params={"term": "infinite monkey cage", "entity": "podcast"},
                )
        names = [result["collectionName"] for result in response.json()["results"]]
        assert names[0] == "The Infinite Monkey Cage"

    async def test_a_blog_is_not_in_the_directory(self, world):
        with stub_world(world):
            async with httpx.AsyncClient() as client:
                response = await client.get("https://itunes.apple.com/search", params={"term": "astral codex ten"})
        assert response.json()["resultCount"] == 0

    async def test_a_feed_parses_back_into_the_episodes_it_was_built_from(self, world):
        from audioreader.feeds.parser import parse_feed

        monkey_cage = next(show for show in world if show.key == "infinite_monkey_cage")
        with stub_world(world):
            async with httpx.AsyncClient() as client:
                response = await client.get(monkey_cage.feed_url)
        parsed = parse_feed(response.content)
        assert parsed.title == "The Infinite Monkey Cage"
        assert [item.title for item in parsed.items] == [item.title for item in monkey_cage.items]
        assert parsed.items[0].audio_url

    async def test_a_homepage_advertises_its_feed(self, world):
        from audioreader.feeds.discovery import resolve_feed

        with stub_world(world):
            feed_url, parsed = await resolve_feed("https://slowboring.com")
        assert feed_url == "https://www.slowboring.com/feed"
        assert parsed.title == "Slow Boring"

    async def test_the_rest_of_the_internet_is_not_there(self, world):
        # A missing stub must look like an unreachable feed, not like a silent
        # success or a real request leaving the machine.
        with stub_world(world), pytest.raises(httpx.ConnectError):
            async with httpx.AsyncClient() as client:
                await client.get("https://example.org/feed.xml")


A_CASE = corpus.Case(
    id="example",
    said="play the one about dark matter",
    expect=corpus.Expect(Action.PLAY_EPISODE, episode="iot-dark-matter"),
    why="because",
)

A_RIGHT_ANSWER = Observed(
    action=Action.PLAY_EPISODE,
    spoken="Playing Dark Matter.",
    episode_guid="iot-dark-matter",
    episode_show="In Our Time",
    episode_title="Dark Matter",
)


class TestGrading:
    def case(self, **overrides) -> corpus.Case:
        return replace(A_CASE, **overrides)

    def observed(self, **overrides) -> Observed:
        return replace(A_RIGHT_ANSWER, **overrides)

    def test_the_right_episode_passes(self):
        assert grade(self.case(), self.observed())[0] is Grade.PASS

    def test_the_wrong_episode_fails(self):
        verdict, detail = grade(self.case(), self.observed(episode_guid="iot-sappho"))
        assert verdict is Grade.FAIL
        assert "wrong episode" in detail

    def test_a_question_is_its_own_verdict(self):
        asked = self.observed(action=Action.UNKNOWN, spoken="Which one?", episode_guid=None)
        assert grade(self.case(), asked)[0] is Grade.ASKED

    def test_a_question_fails_when_the_request_was_clear(self):
        verdict, _ = grade(
            self.case(question_is_acceptable=False),
            self.observed(action=Action.UNKNOWN, spoken="Which one?", episode_guid=None),
        )
        assert verdict is Grade.FAIL

    def test_silence_always_fails(self):
        verdict, detail = grade(self.case(), self.observed(action=Action.UNKNOWN, spoken="  ", episode_guid=None))
        assert verdict is Grade.FAIL
        assert "silent" in detail

    def test_silence_fails_even_when_a_question_was_the_expected_answer(self):
        # Observed for real: the model chose unknown and said nothing, which
        # leaves her in silence with no way to tell whether anything happened.
        case = self.case(expect=corpus.Expect(Action.UNKNOWN))
        verdict, _ = grade(case, self.observed(action=Action.UNKNOWN, spoken="", episode_guid=None))
        assert verdict is Grade.FAIL

    def test_an_answer_in_another_script_fails(self):
        # Also observed for real: asked about Athelstan, the model asked its
        # clarifying question in Chinese. An English voice reads that as noise.
        case = self.case(expect=corpus.Expect(Action.UNKNOWN))
        chinese = self.observed(action=Action.UNKNOWN, spoken="您说的是哪一期节目？", episode_guid=None)
        assert grade(case, chinese)[0] is Grade.FAIL

    def test_accented_latin_is_still_readable(self):
        for spoken in ("Playing Æthelstan.", "Playing the Rubaiyat.", "Playing Björk."):
            assert readable_aloud(spoken), spoken

    def test_a_ruled_out_episode_fails_even_with_the_right_action(self):
        case = self.case(
            expect=corpus.Expect(Action.PLAY_EPISODE, any_of=("iot-sappho", "iot-dark-matter")),
            never=("iot-dark-matter",),
        )
        assert grade(case, self.observed())[0] is Grade.FAIL

    def test_subscribing_is_graded_on_the_database_not_the_sentence(self):
        case = self.case(expect=corpus.Expect(Action.SUBSCRIBED, feed="https://a.example/feed"))
        claimed = Observed(
            action=Action.SUBSCRIBED,
            spoken="Subscribed to Whatever.",
            subscribed_added=frozenset(),
        )
        assert grade(case, claimed)[0] is Grade.FAIL
        really = Observed(
            action=Action.SUBSCRIBED,
            spoken="Subscribed to Whatever.",
            subscribed_added=frozenset({"https://a.example/feed"}),
        )
        assert grade(case, really)[0] is Grade.PASS

    def test_speed_must_match_exactly(self):
        case = self.case(expect=corpus.Expect(Action.SET_SPEED, speed=1.5))
        assert grade(case, Observed(Action.SET_SPEED, "2 times speed.", speed=2.0))[0] is Grade.FAIL
        assert grade(case, Observed(Action.SET_SPEED, "1.5 times.", speed=1.5))[0] is Grade.PASS

    def test_a_required_phrase_must_be_said(self):
        case = self.case(expect=corpus.Expect(Action.UNKNOWN, says=("history", "politics")))
        asked_badly = Observed(Action.UNKNOWN, "Which show did you mean?")
        assert grade(case, asked_badly)[0] is Grade.FAIL
        asked_well = Observed(Action.UNKNOWN, "Did you mean The Rest Is History or Politics?")
        assert grade(case, asked_well)[0] is Grade.PASS


class TestRunner:
    async def test_a_case_runs_end_to_end_against_a_stubbed_model(self, world):
        # The pipeline, the world and the grader together, with the model
        # replaced by a scripted answer.
        case = corpus.by_id("recent-by-topic")

        class Scripted:
            model = "scripted"

            async def decide(self, *, system, user, output_model):
                # Read the id back out of the prompt the service built, which
                # is what a real model would be doing too.
                for line in user.splitlines():
                    if "] Dark Matter " in line:
                        return {
                            "action": "play_episode",
                            "episode_id": int(line.split("]")[0].lstrip("[")),
                            "spoken_response": "Playing Dark Matter.",
                        }
                return {"action": "unknown", "spoken_response": "Sorry?"}

        with stub_world(world):
            result = await run_case(case, world, Scripted())

        assert result.grade is Grade.PASS
        assert result.llm_calls == 1

    async def test_a_model_error_is_not_counted_as_a_wrong_answer(self, world):
        from audioreader.llm.client import LLMError

        with stub_world(world):
            result = await run_case(corpus.by_id("recent-by-topic"), world, FakeLLMClient(error=LLMError("upstream")))
        assert result.grade is Grade.ERROR

    async def test_cases_do_not_leak_into_each_other(self, world):
        # Each case gets its own database, so a case that subscribes to
        # something cannot change what a later case is offered.
        subscribe = FakeLLMClient(
            {
                "action": "subscribe",
                "search_query": "The Rest Is Entertainment",
                "spoken_response": "",
            }
        )
        with stub_world(world):
            first = await run_case(corpus.by_id("subscribe-podcast"), world, subscribe)
            second = await run_case(corpus.by_id("subscribe-podcast"), world, subscribe)
        assert first.grade is Grade.PASS
        assert second.grade is Grade.PASS


class TestObserved:
    def test_reads_the_episode_and_show_off_the_result(self):
        feed = Feed(url="https://a.example/feed", title="In Our Time")
        episode = Episode(guid="iot-sleep", title="Sleep", feed=feed)
        observed = Observed.of(
            InterpretResult(Action.PLAY_EPISODE, "Playing Sleep.", episode=episode),
            frozenset(),
            frozenset(),
        )
        assert observed.episode_guid == "iot-sleep"
        assert observed.episode_show == "In Our Time"
        assert "Sleep" in observed.describe()

    async def test_subscription_changes_come_from_the_database(self, session, user, world):
        await seed(session, user, world)
        from evals.runner import subscribed_urls

        before = await subscribed_urls(session, user)
        feed = Feed(url="https://new.example/feed", title="Something New")
        session.add(feed)
        session.add(Subscription(user_id=user.id, feed=feed))
        await session.commit()
        after = await subscribed_urls(session, user)

        assert after - before == {"https://new.example/feed"}
