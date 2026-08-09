"""Subscribing to a blog by voice: the directory fails, web discovery saves it."""

from sqlalchemy import select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.feeds.discovery import DiscoveredFeed, find_feed_by_name
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
    async def test_blog_not_in_directory_is_found_and_subscribed(
        self, session, user, respx_mock, article_xml
    ):
        empty_itunes(respx_mock)
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient()
        llm.queue(subscribe_decision("notes on progress"), candidates(SITE_URL))

        result = await service.interpret(
            session, llm, user=user, transcript="subscribe to notes on progress"
        )

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

        result = await service.interpret(
            session, llm, user=user, transcript="subscribe to an obscure zine"
        )

        assert result.action == Action.UNKNOWN
        assert "an obscure zine" in result.spoken_response

    async def test_directory_outage_still_tries_discovery(
        self, session, user, respx_mock, article_xml
    ):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        llm = FakeLLMClient()
        llm.queue(subscribe_decision("notes on progress"), candidates(SITE_URL))

        result = await service.interpret(
            session, llm, user=user, transcript="subscribe to notes on progress"
        )

        assert result.action == Action.SUBSCRIBED


class TestPlayFromUnknownPublication:
    async def test_latest_article_plays_without_subscribing(
        self, session, user, respx_mock, article_xml
    ):
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

        result = await service.interpret(
            session, llm, user=user, transcript="play the latest notes on progress"
        )

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.title == "Why sewers made cities possible"
        # Played, not followed.
        assert (await session.scalar(select(Feed))).url == FEED_URL
