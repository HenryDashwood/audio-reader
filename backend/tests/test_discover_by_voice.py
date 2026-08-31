"""Subscribing to a blog by voice: the directory fails, web discovery saves it."""

import asyncio

from sqlalchemy import select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.feeds.discovery import DiscoveredFeed, find_feed_by_name, substack_guesses
from audioreader.feeds.search import loosely_identifies
from audioreader.llm.client import LLMError
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Feed

SEARCH_URL = "https://itunes.apple.com/search"
SITE_URL = "https://notesonprogress.example.com"
FEED_URL = "https://notesonprogress.example.com/feed"

HOMEPAGE = b"""
<html><head><title>Home</title>
<link rel="alternate" type="application/rss+xml" href="/feed">
</head><body>Essays.</body></html>
"""


def empty_itunes(respx_mock):
    respx_mock.get(SEARCH_URL).respond(json={"resultCount": 0, "results": []})


def candidates(*urls: str, publication: str = "Notes on Progress") -> dict:
    return {"publication": publication, "urls": list(urls)}


def subscribe_decision(query: str) -> dict:
    return {"action": "subscribe", "search_query": query, "spoken_response": ""}


class TestLooseIdentification:
    def test_names_glued_into_domains_match(self):
        assert loosely_identifies(
            "liam halligan's substack",
            "When The Facts Change https://liamhalligan.substack.com/feed",
        )

    def test_unrelated_names_do_not_match(self):
        assert not loosely_identifies(
            "completely different name",
            "When The Facts Change https://liamhalligan.substack.com/feed",
        )

    def test_all_filler_matches_nothing(self):
        assert not loosely_identifies("the substack", "anything at all")

    def test_split_substack_is_a_medium_not_part_of_the_name(self):
        assert loosely_identifies(
            "semi analysis sub stack",
            "SemiAnalysis https://newsletter.semianalysis.com/feed",
        )


class TestSubstackGuess:
    def test_guesses_built_from_meaningful_words(self):
        assert substack_guesses("liam halligan's substack") == [
            "https://liamhalligan.substack.com/feed",
            "https://liam-halligan.substack.com/feed",
        ]
        # No "substack" spoken: no reason to guess.
        assert substack_guesses("the rest is history") == []

    def test_split_dictation_form_builds_the_same_guesses(self):
        assert substack_guesses("semi analysis sub stack") == [
            "https://semianalysis.substack.com/feed",
            "https://semi-analysis.substack.com/feed",
        ]

    async def test_substack_phrasing_skips_the_model_entirely(self, respx_mock, article_xml):
        xml = article_xml.replace(b"Notes on Progress", b"When The Facts Change")
        respx_mock.get("https://liamhalligan.substack.com/feed").respond(
            content=xml, content_type="application/rss+xml"
        )
        llm = FakeLLMClient()  # would raise if consulted

        found = await find_feed_by_name("liam halligan's substack", llm)

        assert found is not None
        assert found.feed_url == "https://liamhalligan.substack.com/feed"
        assert found.title == "When The Facts Change"
        assert llm.calls == []

    async def test_wrong_guess_falls_through_to_the_model(self, respx_mock, article_xml):
        # The guessed subdomain 404s; the model's candidate still wins.
        respx_mock.get("https://notesonprogress.substack.com/feed").respond(status_code=404)
        respx_mock.get("https://notes-on-progress.substack.com/feed").respond(status_code=404)
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(candidates(FEED_URL))

        found = await find_feed_by_name("notes on progress substack", llm)

        assert found is not None
        assert found.feed_url == FEED_URL


class TestSpokenDomains:
    def test_literal_domains_are_found_in_sentences(self):
        from audioreader.feeds.discovery import spoken_domains

        assert spoken_domains("subscribe to the rss feed of astralcodexten.com") == ["astralcodexten.com"]

    def test_spelled_out_domains_are_reassembled_longest_first(self):
        from audioreader.feeds.discovery import spoken_domains

        # "astral codex ten dot com": only "ten" touches the dot, so the
        # preceding words are glued on, most complete candidate first.
        domains = spoken_domains("subscribe to the rss feed of astral codex ten dot com")
        assert domains[0] == "astralcodexten.com"
        assert "ten.com" in domains

    def test_command_words_do_not_leak_into_the_domain(self):
        from audioreader.feeds.discovery import spoken_domains

        domains = spoken_domains("play the feed of henry dashwood.com")
        assert domains[0] == "henrydashwood.com"
        assert not any("feed" in domain for domain in domains)

    def test_plain_names_yield_nothing(self):
        from audioreader.feeds.discovery import spoken_domains

        assert spoken_domains("subscribe to the rest is history") == []


class TestSpokenDomainBeatsTheDirectory:
    async def test_naming_a_site_subscribes_to_its_feed_not_a_similar_podcast(
        self, session, user, respx_mock, article_xml
    ):
        # The podcast directory has a plausible match — but she named the
        # site itself, so its own article feed must win.
        respx_mock.get(SEARCH_URL).respond(
            json={
                "resultCount": 1,
                "results": [
                    {
                        "collectionName": "Notes on Progress Podcast",
                        "artistName": "Someone Else",
                        "feedUrl": "https://podcasts.example.com/notes.rss",
                    }
                ],
            }
        )
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(
            # The model stripped the domain down to a bare name — the raw
            # transcript still carries it.
            subscribe_decision("notes on progress")
        )

        result = await service.interpret(
            session,
            llm,
            user=user,
            transcript="subscribe to the rss feed of notesonprogress.example.com",
        )

        assert result.action == Action.SUBSCRIBED
        assert "Notes on Progress" in result.spoken_response
        assert (await session.scalar(select(Feed))).url == FEED_URL


class TestFindFeedByName:
    async def test_verifies_and_returns_the_discovered_feed(self, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(candidates(SITE_URL))

        found = await find_feed_by_name("notes on progress", llm)

        assert found == DiscoveredFeed(feed_url=FEED_URL, title="Notes on Progress")

    async def test_bare_domains_get_a_scheme(self, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(candidates("notesonprogress.example.com"))

        found = await find_feed_by_name("notes on progress", llm)

        assert found is not None
        assert found.feed_url == FEED_URL

    async def test_a_feed_that_does_not_match_the_name_is_rejected(self, respx_mock, podcast_xml):
        # The model proposes a real feed — for the wrong publication. Without
        # the guard she would be subscribed to a stranger's writing.
        respx_mock.get(FEED_URL).respond(content=podcast_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(candidates(FEED_URL, publication="The History Hour"))

        found = await find_feed_by_name("completely different name", llm)

        assert found is None
        # Both attempts ran: the second is told what failed.
        assert len(llm.calls) == 2
        assert FEED_URL in llm.calls[1]["user"]

    async def test_dead_candidates_are_skipped_for_live_ones(self, respx_mock, article_xml):
        respx_mock.get("https://gone.example.com/").respond(status_code=404)
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient(candidates("https://gone.example.com", FEED_URL))

        found = await find_feed_by_name("notes on progress", llm)

        assert found is not None
        assert found.feed_url == FEED_URL

    async def test_model_failure_returns_none(self):
        llm = FakeLLMClient()
        llm.fail_with(LLMError("model unavailable"))
        assert await find_feed_by_name("anything", llm) is None


class TestSubscribeFallsBackToDiscovery:
    async def test_split_substack_transcript_finds_semianalysis_without_web_search(
        self, session, user, respx_mock, article_xml
    ):
        directory = respx_mock.get(SEARCH_URL).respond(json={"resultCount": 0, "results": []})
        xml = article_xml.replace(b"Notes on Progress", b"SemiAnalysis")
        respx_mock.get("https://semianalysis.substack.com/feed").respond(
            content=xml,
            content_type="application/rss+xml",
        )
        llm = FakeLLMClient(subscribe_decision("semi analysis sub stack"))

        result = await service.interpret(
            session,
            llm,
            user=user,
            transcript="subscribe to semi analysis sub stack",
        )

        assert result.action == Action.SUBSCRIBED
        assert result.spoken_response == "Subscribed to SemiAnalysis."
        assert directory.calls.last.request.url.params["term"] == "semi analysis"
        # Only the command decision: deterministic Substack discovery avoids
        # both expensive web-search attempts.
        assert len(llm.calls) == 1

    async def test_blog_not_in_directory_is_found_and_subscribed(self, session, user, respx_mock, article_xml):
        empty_itunes(respx_mock)
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient()
        llm.queue(subscribe_decision("notes on progress"), candidates(SITE_URL))

        result = await service.interpret(session, llm, user=user, transcript="subscribe to notes on progress")

        assert result.action == Action.SUBSCRIBED
        assert "Notes on Progress" in result.spoken_response
        feed = await session.scalar(select(Feed))
        assert feed.url == FEED_URL

    async def test_discovery_failure_is_explained_aloud(self, session, user, respx_mock):
        empty_itunes(respx_mock)
        llm = FakeLLMClient()
        llm.queue(
            subscribe_decision("an obscure zine"),
            candidates(publication=""),  # no URLs: model does not know it
            candidates(publication=""),
        )

        result = await service.interpret(session, llm, user=user, transcript="subscribe to an obscure zine")

        assert result.action == Action.UNKNOWN
        assert "an obscure zine" in result.spoken_response

    async def test_voice_discovery_has_a_firm_deadline(self, session, user, respx_mock, monkeypatch):
        empty_itunes(respx_mock)

        async def stalled_discovery(*_args, **_kwargs):
            await asyncio.sleep(1)

        monkeypatch.setattr(service, "find_feed_by_name", stalled_discovery)
        monkeypatch.setattr(service, "_VOICE_DISCOVERY_TIMEOUT_SECONDS", 0.01)

        result = await service.interpret(
            session,
            FakeLLMClient(subscribe_decision("an obscure zine")),
            user=user,
            transcript="subscribe to an obscure zine",
        )

        assert result.action == Action.UNKNOWN
        assert "an obscure zine" in result.spoken_response

    async def test_directory_outage_still_tries_discovery(self, session, user, respx_mock, article_xml):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient()
        llm.queue(subscribe_decision("notes on progress"), candidates(SITE_URL))

        result = await service.interpret(session, llm, user=user, transcript="subscribe to notes on progress")

        assert result.action == Action.SUBSCRIBED


class TestPlayFromUnknownPublication:
    async def test_latest_article_plays_without_subscribing(self, session, user, respx_mock, article_xml):
        empty_itunes(respx_mock)
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient()
        llm.queue(
            {
                "action": "play_from_show",
                "search_query": "notes on progress",
                "episode_query": "",
                "spoken_response": "",
            },
            candidates(SITE_URL),
        )

        result = await service.interpret(session, llm, user=user, transcript="play the latest notes on progress")

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.title == "Why sewers made cities possible"
        # Played, not followed.
        assert (await session.scalar(select(Feed))).url == FEED_URL
