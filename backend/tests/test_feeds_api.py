from datetime import UTC, datetime, timedelta

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import Episode, Feed, PlaybackPosition, User

FEED_URL = "https://example.com/feed.xml"


async def subscribe(client, respx_mock, xml: bytes, url: str = FEED_URL):
    respx_mock.get(url).respond(content=xml, content_type="application/rss+xml")
    return await client.post("/feeds", json={"url": url})


async def add_new_episode(
    session,
    feed_id: int,
    *,
    number: int,
    title: str | None = None,
    article: bool = False,
) -> Episode:
    """An item ingested after subscription, which therefore belongs in Latest."""
    episode = Episode(
        feed_id=feed_id,
        guid=f"new-{number}",
        title=title or f"New episode {number}",
        audio_url=None if article else f"https://cdn.example.com/new-{number}.mp3",
        content_html="<p>A new article.</p>" if article else None,
        published_at=datetime(2026, 8, 1, tzinfo=UTC) + timedelta(days=number),
        image_url=f"https://example.com/new-{number}.jpg",
    )
    session.add(episode)
    await session.commit()
    return episode


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
        assert response.json()["is_article_feed"] is True

    async def test_article_feed_uses_website_open_graph_artwork(self, client, respx_mock, article_xml):
        artwork = "https://notesonprogress.example.com/images/social-card.jpg"
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.get("https://notesonprogress.example.com/").respond(
            content=f'<html><head><meta property="og:image" content="{artwork}"></head></html>',
            content_type="text/html",
        )

        response = await client.post("/feeds/preview", json={"url": FEED_URL})

        assert response.status_code == 200
        assert response.json()["feed"]["image_url"] == artwork
        assert all(episode["image_url"] == artwork for episode in response.json()["episodes"])

    async def test_duplicate_url_conflicts(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 409

    async def test_non_feed_content_rejected(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(content=b"<html>not a feed</html>")
        # Autodiscovery probes the conventional feed paths before giving up.
        respx_mock.route().respond(status_code=404)
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 422

    async def test_unreachable_feed_is_bad_gateway(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(status_code=500)
        response = await client.post("/feeds", json={"url": FEED_URL})
        assert response.status_code == 502


class TestPreview:
    async def preview(self, client, respx_mock, xml: bytes, url: str = FEED_URL):
        respx_mock.get(url).respond(content=xml, content_type="application/rss+xml")
        return await client.post("/feeds/preview", json={"url": url})

    async def test_returns_show_and_playable_episodes(self, client, respx_mock, podcast_xml):
        response = await self.preview(client, respx_mock, podcast_xml)

        assert response.status_code == 200
        body = response.json()
        assert body["feed"]["title"] == "The History Hour"
        assert body["feed"]["episode_count"] == 3
        assert body["subscribed"] is False
        assert [e["title"] for e in body["episodes"]][0] == "The Fall of Constantinople"
        assert body["episodes"][0]["audio_url"] == "https://cdn.example.com/hh/103.mp3"
        assert body["episodes"][0]["id"]

    async def test_previewing_does_not_subscribe(self, client, respx_mock, podcast_xml):
        await self.preview(client, respx_mock, podcast_xml)
        assert (await client.get("/feeds")).json() == []

    async def test_a_subscribed_feed_says_so(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        response = await client.post("/feeds/preview", json={"url": FEED_URL})
        assert response.json()["subscribed"] is True

    async def test_a_catalogued_feed_is_not_refetched(self, client, respx_mock, podcast_xml):
        route = respx_mock.get(FEED_URL).respond(content=podcast_xml, content_type="application/rss+xml")
        await client.post("/feeds/preview", json={"url": FEED_URL})
        await client.post("/feeds/preview", json={"url": FEED_URL})
        assert route.call_count == 1

    async def test_reopening_an_old_preview_backfills_website_artwork(self, client, session, respx_mock, article_xml):
        site_url = "https://notesonprogress.example.com/"
        artwork = f"{site_url}social-card.jpg"
        feed_route = respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.get(site_url).respond(content=b"<html><head></head></html>", content_type="text/html")
        first = await client.post("/feeds/preview", json={"url": FEED_URL})
        feed = await session.get(Feed, first.json()["feed"]["id"])
        # This is the state produced by deploying the migration over a catalog
        # row that existed before website artwork fallback was introduced.
        feed.site_image_url = None
        feed.site_artwork_checked_at = None
        await session.commit()
        respx_mock.get(site_url).respond(
            content=f'<html><head><meta property="og:image" content="{artwork}"></head></html>',
            content_type="text/html",
        )

        reopened = await client.post("/feeds/preview", json={"url": FEED_URL})

        assert reopened.status_code == 200
        assert reopened.json()["feed"]["image_url"] == artwork
        assert all(episode["image_url"] == artwork for episode in reopened.json()["episodes"])
        assert feed_route.call_count == 1

    async def test_subscribing_after_preview_is_instant(self, client, respx_mock, podcast_xml):
        # The preview already ingested the feed; subscribing must not refetch.
        route = respx_mock.get(FEED_URL).respond(content=podcast_xml, content_type="application/rss+xml")
        await client.post("/feeds/preview", json={"url": FEED_URL})
        response = await client.post("/feeds", json={"url": FEED_URL})

        assert response.status_code == 201
        assert route.call_count == 1
        titles = [feed["title"] for feed in (await client.get("/feeds")).json()]
        assert titles == ["The History Hour"]

    async def test_previewed_episode_is_fetchable_and_positionable(self, client, respx_mock, podcast_xml):
        # She can play from a preview, so resume must work there too.
        body = (await self.preview(client, respx_mock, podcast_xml)).json()
        episode_id = body["episodes"][0]["id"]

        put = await client.put(f"/episodes/{episode_id}/position", json={"position_seconds": 90.0})
        assert put.status_code == 204
        single = (await client.get(f"/episodes/{episode_id}")).json()
        assert single["position_seconds"] == 90.0

    async def test_non_feed_content_rejected(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(content=b"<html>not a feed</html>")
        respx_mock.route().respond(status_code=404)
        response = await client.post("/feeds/preview", json={"url": FEED_URL})
        assert response.status_code == 422

    async def test_unreachable_feed_is_bad_gateway(self, client, respx_mock):
        respx_mock.get(FEED_URL).respond(status_code=500)
        response = await client.post("/feeds/preview", json={"url": FEED_URL})
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

    # A blog's items are posts, and the app only knows to call them that
    # because the listing says the feed carries no audio at all.
    async def test_a_feed_without_audio_is_marked_an_article_feed(self, client, respx_mock, article_xml):
        await subscribe(client, respx_mock, article_xml)
        assert (await client.get("/feeds")).json()[0]["is_article_feed"] is True

    async def test_a_podcast_is_not_an_article_feed(self, client, respx_mock, podcast_xml):
        await subscribe(client, respx_mock, podcast_xml)
        assert (await client.get("/feeds")).json()[0]["is_article_feed"] is False


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

    async def test_episode_identifies_its_containing_feed(self, client, respx_mock, podcast_xml):
        response = await subscribe(client, respx_mock, podcast_xml)
        feed = response.json()
        episode = (await client.get(f"/feeds/{feed['id']}/episodes")).json()[0]

        assert episode["feed_title"] == "The History Hour"
        assert episode["feed_url"] == feed["url"]

    async def test_episode_carries_its_byline(self, client, respx_mock, article_xml):
        # Preserve item authorship as distinct metadata from the containing
        # publication that the reader links above the first paragraph.
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episodes = (await client.get(f"/feeds/{feed_id}/episodes")).json()
        assert episodes[0]["author"] == "Ada Whitfield"
        assert episodes[1]["author"] is None

    async def test_episode_artwork_prefers_item_image(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        episodes = (await client.get(f"/feeds/{feed_id}/episodes")).json()
        # First item declares its own artwork; the others inherit the show's.
        assert episodes[0]["image_url"] == "https://example.com/historyhour/ep103.jpg"
        assert episodes[1]["image_url"] == "https://example.com/historyhour/cover.jpg"

    async def test_episode_artwork_in_recent_and_single(self, client, session, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        arrived = await add_new_episode(session, feed_id, number=103)
        recent = (await client.get("/episodes")).json()
        assert recent[0]["image_url"] == "https://example.com/new-103.jpg"
        single = (await client.get(f"/episodes/{arrived.id}")).json()
        assert single["image_url"] == "https://example.com/new-103.jpg"

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
    async def test_a_new_subscription_starts_caught_up(self, client, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]

        assert (await client.get("/episodes")).json() == []
        # Its archive has not gone anywhere; only Latest starts at the end.
        assert len((await client.get(f"/feeds/{feed_id}/episodes")).json()) == 3

    async def test_lists_new_arrivals_newest_first(self, client, session, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        await add_new_episode(session, feed_id, number=1)
        await add_new_episode(session, feed_id, number=2)
        response = await client.get("/episodes")

        assert response.status_code == 200
        titles = [e["title"] for e in response.json()]
        assert titles == ["New episode 2", "New episode 1"]

    async def test_new_articles_are_playable_too(self, client, session, respx_mock, article_xml):
        # Articles are read aloud by the app, so they belong in Latest and in
        # Siri's suggestions alongside audio episodes.
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        await add_new_episode(
            session,
            feed_id,
            number=3,
            title="The future of clean water",
            article=True,
        )
        episodes = (await client.get("/episodes")).json()
        assert [e["title"] for e in episodes] == ["The future of clean water"]
        assert all(e["audio_url"] is None and e["has_text"] for e in episodes)

    async def test_respects_limit(self, client, session, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        for number in range(3):
            await add_new_episode(session, feed_id, number=number)
        assert len((await client.get("/episodes?limit=2")).json()) == 2

    async def test_clearing_advances_past_the_whole_inbox(self, client, session, respx_mock, podcast_xml):
        feed_id = (await subscribe(client, respx_mock, podcast_xml)).json()["id"]
        for number in range(55):
            await add_new_episode(session, feed_id, number=number)
        assert len((await client.get("/episodes?limit=50")).json()) == 50

        response = await client.delete("/episodes")

        assert response.status_code == 204
        assert (await client.get("/episodes")).json() == []
        # Clear is not a claim that she listened to 55 episodes.
        assert await session.scalar(select(func.count()).select_from(PlaybackPosition)) == 0
        assert len((await client.get(f"/feeds/{feed_id}/episodes?limit=100")).json()) == 58

        arrived = await add_new_episode(session, feed_id, number=100)
        assert [item["id"] for item in (await client.get("/episodes")).json()] == [arrived.id]

    async def test_rejects_unbounded_limits(self, client):
        assert (await client.get("/episodes?limit=0")).status_code == 422
        assert (await client.get("/episodes?limit=1000000")).status_code == 422


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
        route = respx_mock.get(FEED_URL).respond(content=podcast_xml, content_type="application/rss+xml")
        await client.post("/feeds", json={"url": FEED_URL})

        other = User(display_name="Other")
        session.add(other)
        await session.commit()
        async with make_client(other) as other_client:
            response = await other_client.post("/feeds", json={"url": FEED_URL})

        # 201, not 409 — and the feed was not fetched a second time.
        assert response.status_code == 201
        assert route.call_count == 1

    async def test_feed_lists_are_per_user(self, client, session, make_client, respx_mock, podcast_xml):
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
        # A bare app without the get_current_user override, so the real auth
        # dependency runs.
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
