from httpx import ASGITransport, AsyncClient

from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import User

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


class TestSingleEpisode:
    async def test_returns_the_episode(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        episode_id = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]["id"]

        response = await client.get(f"/episodes/{episode_id}")

        assert response.status_code == 200
        assert response.json()["title"] == "The Fall of Constantinople"
        assert response.json()["audio_url"] == "https://cdn.example.com/hh/103.mp3"

    async def test_unknown_episode_is_404(self, client):
        assert (await client.get("/episodes/9999")).status_code == 404


class TestRecentEpisodes:
    async def test_lists_newest_across_all_feeds(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        response = await client.get("/episodes")

        assert response.status_code == 200
        titles = [e["title"] for e in response.json()]
        assert titles[0] == "The Fall of Constantinople"

    async def test_only_playable_episodes(self, client, respx_mock, article_xml):
        # Siri suggestions must not offer something that cannot be played.
        await subscribe(client, respx_mock, article_xml)
        assert (await client.get("/episodes")).json() == []

    async def test_respects_limit(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        assert len((await client.get("/episodes?limit=2")).json()) == 2


class TestUnsubscribeEndpoint:
    async def test_removes_the_subscription(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]

        assert (await client.delete(f"/feeds/{feed_id}")).status_code == 204
        assert (await client.get("/feeds")).json() == []

    async def test_not_subscribed_is_404(self, client):
        assert (await client.delete("/feeds/999")).status_code == 404


class TestSharedCatalog:
    async def test_second_user_can_subscribe_to_an_existing_feed(
        self, client, session, make_client, respx_mock, podcast_xml
    ):
        route = respx_mock.get(FEED_URL).respond(
            content=podcast_xml, content_type="application/rss+xml"
        )
        await client.post("/feeds", json={"url": FEED_URL})

        other = User(display_name="Other")
        session.add(other)
        await session.commit()
        async with make_client(other) as other_client:
            response = await other_client.post("/feeds", json={"url": FEED_URL})

        # 201, not 409 — and the feed was not fetched a second time.
        assert response.status_code == 201
        assert route.call_count == 1

    async def test_feed_lists_are_per_user(
        self, client, session, make_client, respx_mock, podcast_xml
    ):
        await subscribe(client, respx_mock, podcast_xml)

        other = User(display_name="Other")
        session.add(other)
        await session.commit()
        async with make_client(other) as other_client:
            assert (await other_client.get("/feeds")).json() == []
            assert (await other_client.get("/episodes")).json() == []

    async def test_unsubscribing_leaves_the_other_user_intact(
        self, client, session, make_client, respx_mock, podcast_xml
    ):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        other = User(display_name="Other")
        session.add(other)
        await session.commit()
        async with make_client(other) as other_client:
            await other_client.post("/feeds", json={"url": FEED_URL})
            await client.delete(f"/feeds/{feed_id}")

            assert (await client.get("/feeds")).json() == []
            titles = [feed["title"] for feed in (await other_client.get("/feeds")).json()]
        assert titles == ["The History Hour"]


class TestAuthRequired:
    async def test_no_token_is_401_with_spoken_error(self, session):
        # A bare app without the get_current_user override: the real auth
        # dependency runs, and require_auth defaults to True.
        app = create_app()
        app.dependency_overrides[get_session] = lambda: session
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.get("/feeds")

        assert response.status_code == 401
        assert "spoken_response" in response.json()["detail"]


class TestDescriptionsAreDisplayReady:
    async def test_feed_description_has_no_markup(self, client, respx_mock, podcast_xml):
        # Clients should never have to parse HTML to show a show's blurb.
        respx_mock.get(FEED_URL).respond(
            content=podcast_xml.replace(
                b"A weekly podcast about history.",
                b"<p>A <em>weekly</em> podcast &amp; more.</p>",
            )
        )
        await client.post("/feeds", json={"url": FEED_URL})

        description = (await client.get("/feeds")).json()[0]["description"]
        assert "<" not in description
        assert description == "A weekly podcast & more."

    async def test_episode_description_has_no_markup(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        episodes = (await client.get(f"/feeds/{feed_id}/episodes")).json()
        assert all("<" not in (e["description"] or "") for e in episodes)

    async def test_a_missing_description_stays_missing(self, client, respx_mock, article_xml):
        await subscribe(client, respx_mock, article_xml)
        # Absent is different from empty: clients hide the row entirely.
        assert (await client.get("/feeds")).json()[0]["description"] is not None
