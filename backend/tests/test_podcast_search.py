import json

import httpx
import pytest

from audioreader.feeds.search import (
    PodcastMatch,
    PodcastSearchError,
    search_podcasts,
    select_unambiguous_match,
)

SEARCH_URL = "https://itunes.apple.com/search"
DEFAULT_FEED = object()


def itunes(*shows: dict) -> dict:
    return {"resultCount": len(shows), "results": list(shows)}


def show(name: str, feed: str | None | object = DEFAULT_FEED, **extra) -> dict:
    if feed is DEFAULT_FEED:
        slug = name.casefold().replace(" ", "-").replace(":", "").replace("!", "")
        feed = f"https://feeds.example.com/{slug}"
    return {
        "collectionName": name,
        "artistName": extra.get("artist", "Some Publisher"),
        "feedUrl": feed,
        "trackCount": extra.get("episodes", 100),
    }


class TestSearchPodcasts:
    async def test_returns_matches(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(show("The Rest Is History", "https://feeds.megaphone.fm/GLT4787413333"))
        )
        results = await search_podcasts("the rest is history")

        assert len(results) == 1
        assert results[0].title == "The Rest Is History"
        assert results[0].feed_url == "https://feeds.megaphone.fm/GLT4787413333"
        assert results[0].publisher == "Some Publisher"

    async def test_sends_the_query_as_a_podcast_search(self, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes(show("A")))
        await search_podcasts("in our time")

        params = route.calls.last.request.url.params
        assert params["term"] == "in our time"
        assert params["entity"] == "podcast"

    async def test_sends_the_listener_storefront(self, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes(show("In Our Time")))
        await search_podcasts("in our time", country="GB")

        assert route.calls.last.request.url.params["country"] == "gb"

    async def test_reuses_a_recent_result_without_an_upstream_call(self, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes(show("In Our Time")))

        await search_podcasts("in our time")
        await search_podcasts("In Our Time")

        assert route.call_count == 1

    async def test_skips_results_with_no_feed(self, respx_mock):
        # A podcast with no RSS feed is useless to us, however well it matches.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("History Weekly", feed=None), show("History Daily")))
        results = await search_podcasts("history daily")

        assert [r.title for r in results] == ["History Daily"]

    async def test_no_matches_returns_empty(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        assert await search_podcasts("nonsense query") == []

    async def test_upstream_failure_raises(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        with pytest.raises(PodcastSearchError):
            await search_podcasts("anything")

    async def test_transport_failure_raises(self, respx_mock):
        respx_mock.get(SEARCH_URL).mock(side_effect=httpx.ConnectError("offline"))
        with pytest.raises(PodcastSearchError):
            await search_podcasts("anything")

    async def test_malformed_body_raises(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(content=b"not json")
        with pytest.raises(PodcastSearchError):
            await search_podcasts("anything")

    async def test_skips_a_malformed_feed_address(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(
                show("Broken", "https://feeds.example.com:not-a-port/show"),
                show("Working"),
            )
        )

        assert [match.title for match in await search_podcasts("working")] == ["Working"]


class TestStrictness:
    async def test_loose_matches_survive_when_not_strict(self, respx_mock):
        # Typed search shows its results on screen, so a loose match is
        # useful there rather than dangerous.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Mortal Realms: A Warhammer Age of Sigmar Podcast")))
        assert await search_podcasts("wibble wobble nonsense", strict=False) != []

    async def test_exact_match_still_promoted_when_not_strict(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Rest Is History: Club"), show("The Rest Is History")))
        results = await search_podcasts("the rest is history", strict=False)
        assert results[0].title == "The Rest Is History"


class TestArtwork:
    async def test_prefers_the_large_artwork(self, respx_mock):
        payload = show("Ancient Warfare")
        payload["artworkUrl100"] = "https://img.example.com/100.jpg"
        payload["artworkUrl600"] = "https://img.example.com/600.jpg"
        respx_mock.get(SEARCH_URL).respond(json=itunes(payload))

        results = await search_podcasts("ancient warfare")
        assert results[0].artwork_url == "https://img.example.com/600.jpg"

    async def test_falls_back_to_the_small_artwork(self, respx_mock):
        payload = show("Ancient Warfare")
        payload["artworkUrl100"] = "https://img.example.com/100.jpg"
        respx_mock.get(SEARCH_URL).respond(json=itunes(payload))

        results = await search_podcasts("ancient warfare")
        assert results[0].artwork_url == "https://img.example.com/100.jpg"

    async def test_missing_artwork_is_none(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Ancient Warfare")))
        results = await search_podcasts("ancient warfare")
        assert results[0].artwork_url is None


class TestRanking:
    async def test_prefers_an_exact_title_match_over_search_order(self, respx_mock):
        # iTunes sometimes puts a spin-off or a discussion podcast first.
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(
                show("The Rest Is History: Club"),
                show("The Rest Is History"),
            )
        )
        results = await search_podcasts("the rest is history")
        assert results[0].title == "The Rest Is History"

    async def test_matching_ignores_case_and_punctuation(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Longer Name Entirely"), show("In Our Time!")))
        results = await search_podcasts("in our time")
        assert results[0].title == "In Our Time!"

    async def test_keeps_search_order_when_nothing_matches_exactly(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("History Weekly"), show("History Daily")))
        results = await search_podcasts("history")
        assert [r.title for r in results] == ["History Weekly", "History Daily"]

    async def test_accepts_an_adjacent_typo(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Rest Is History")))

        results = await search_podcasts("the rest is hsitory")

        assert results[0].title == "The Rest Is History"

    async def test_deduplicates_http_and_https_aliases(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(
                show("History Daily", "http://feeds.example.com/history/"),
                show("History Daily Podcast", "https://feeds.example.com/history#about"),
            )
        )

        results = await search_podcasts("history daily", strict=False)

        assert [match.title for match in results] == ["History Daily"]


class TestVoiceAmbiguity:
    def test_a_unique_exact_title_is_safe(self):
        exact = PodcastMatch(title="History Daily", feed_url="https://feeds.example/daily")
        other = PodcastMatch(title="History Daily Extra", feed_url="https://feeds.example/extra")

        assert select_unambiguous_match([other, exact], "history daily") == exact

    def test_a_generic_query_needs_a_question(self):
        first = PodcastMatch(title="History Daily", feed_url="https://feeds.example/daily")
        second = PodcastMatch(title="History Extra", feed_url="https://feeds.example/extra")

        assert select_unambiguous_match([first, second], "history") is None


class TestRelevance:
    async def test_rejects_results_that_do_not_match_the_words_she_said(self, respx_mock):
        # iTunes almost never returns nothing; it returns something loosely
        # related. Subscribing her to that is worse than admitting defeat.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Mortal Realms: A Warhammer Age of Sigmar Podcast")))
        assert await search_podcasts("wibble wobble nonsense") == []

    async def test_accepts_a_partial_name(self, respx_mock):
        # "put on rogan" should still find the full title.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Joe Rogan Experience")))
        results = await search_podcasts("joe rogan")
        assert results[0].title == "The Joe Rogan Experience"

    async def test_ignores_filler_words_when_matching(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("In Our Time")))
        results = await search_podcasts("the in our time podcast")
        assert results[0].title == "In Our Time"

    async def test_matches_against_the_publisher_too(self, respx_mock):
        # Shows are often asked for by their maker ("the Goalhanger one").
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(show("The Rest Is Politics", feed="https://f/1", artist="Goalhanger"))
        )
        results = await search_podcasts("goalhanger")
        assert len(results) == 1

    async def test_a_single_wrong_word_is_not_enough(self, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History of Rome")))
        assert await search_podcasts("the history hour") == []


class TestPayloadShape:
    async def test_real_world_payload_decodes(self, respx_mock):
        # Captured from the live API, to catch field renames.
        captured = json.dumps(
            {
                "resultCount": 1,
                "results": [
                    {
                        "collectionName": "The Rest Is History",
                        "artistName": "Goalhanger",
                        "feedUrl": "https://feeds.megaphone.fm/GLT4787413333",
                        "trackCount": 967,
                        "primaryGenreName": "History",
                    }
                ],
            }
        )
        respx_mock.get(SEARCH_URL).respond(content=captured.encode())
        results = await search_podcasts("the rest is history")

        assert results[0].title == "The Rest Is History"
        assert results[0].publisher == "Goalhanger"
        assert results[0].episode_count == 967
