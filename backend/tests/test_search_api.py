"""Typed podcast search: GET /search/podcasts."""

SEARCH_URL = "https://itunes.apple.com/search"


def itunes(*shows: dict) -> dict:
    return {"resultCount": len(shows), "results": list(shows)}


def show(name: str, feed: str = "https://feeds.example.com/x", **extra) -> dict:
    return {
        "collectionName": name,
        "artistName": extra.get("artist", "Some Publisher"),
        "feedUrl": feed,
        "trackCount": extra.get("episodes", 100),
        "artworkUrl600": extra.get("artwork", "https://img.example.com/600.jpg"),
    }


class TestSearchPodcasts:
    async def test_returns_directory_matches(self, client, respx_mock):
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(show("The Rest Is History", "https://feeds.megaphone.fm/GLT4787413333"))
        )
        response = await client.get("/search/podcasts", params={"q": "rest is history"})

        assert response.status_code == 200
        body = response.json()
        assert body == [
            {
                "title": "The Rest Is History",
                "feed_url": "https://feeds.megaphone.fm/GLT4787413333",
                "publisher": "Some Publisher",
                "episode_count": 100,
                "artwork_url": "https://img.example.com/600.jpg",
            }
        ]

    async def test_typed_search_is_not_word_filtered(self, client, respx_mock):
        # Voice rejects loose matches because acting on the wrong show is
        # dangerous. Typed results are on screen, so show them all.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Mortal Realms: A Warhammer Age of Sigmar Podcast")))
        body = (await client.get("/search/podcasts", params={"q": "warhammer stuff"})).json()
        assert len(body) == 1

    async def test_asks_the_directory_for_podcasts(self, client, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes())
        await client.get("/search/podcasts", params={"q": "in our time"})

        params = route.calls.last.request.url.params
        assert params["term"] == "in our time"
        assert params["entity"] == "podcast"

    async def test_blank_query_returns_nothing_without_searching(self, client, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes())
        body = (await client.get("/search/podcasts", params={"q": "   "})).json()
        assert body == []
        assert not route.called

    async def test_artwork_is_upgraded_to_https(self, client, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("A Show", artwork="http://img.example.com/a.jpg")))
        body = (await client.get("/search/podcasts", params={"q": "a show"})).json()
        assert body[0]["artwork_url"] == "https://img.example.com/a.jpg"

    async def test_directory_outage_is_bad_gateway(self, client, respx_mock):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        response = await client.get("/search/podcasts", params={"q": "anything"})
        assert response.status_code == 502
