FEED_URL = "https://example.com/feed.xml"


async def subscribe(client, respx_mock, xml: bytes, url: str = FEED_URL):
    respx_mock.get(url).respond(content=xml, content_type="application/rss+xml")
    return await client.post("/feeds", json={"url": url})


class TestSubscribe:
    async def test_creates_feed_with_episodes(self, client, respx_mock, podcast_xml):
        response = await subscribe(client, respx_mock, podcast_xml)
        assert response.status_code == 201
        body = response.json()
        assert body["title"] == "The History Hour"
        assert body["url"] == FEED_URL
        assert body["episode_count"] == 3

    async def test_article_feed_subscribes_too(self, client, respx_mock, article_xml):
        response = await subscribe(client, respx_mock, article_xml)
        assert response.status_code == 201
        assert response.json()["title"] == "Notes on Progress"

    async def test_duplicate_url_conflicts(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 409

    async def test_non_feed_content_rejected(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(content=b"<html>not a feed</html>")
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 422

    async def test_unreachable_feed_is_bad_gateway(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(status_code=500)
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 502


class TestListFeeds:
    async def test_empty_at_first(self, client):
        response = await client.get("/feeds")
        assert response.status_code == 200
        assert response.json() == []

    async def test_lists_subscribed_feeds(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        body = (await client.get("/feeds")).json()
        assert [feed["title"] for feed in body] == ["The History Hour"]


class TestListEpisodes:
    async def test_newest_first(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        body = (await client.get(f"/feeds/{feed_id}/episodes")).json()
        assert [episode["title"] for episode in body] == [
            "The Fall of Constantinople",
            "The South Sea Bubble",
            "Trailer: Season Four",
        ]

    async def test_episode_carries_playback_fields(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]
        assert episode["audio_url"] == "https://cdn.example.com/hh/103.mp3"
        assert episode["duration_seconds"] == 3723
        assert episode["published_at"].startswith("2026-07-28")

    async def test_unknown_feed_is_404(self, client):
        response = await client.get("/feeds/999/episodes")
        assert response.status_code == 404
