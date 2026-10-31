"""Typed podcast and publication search: GET /search/podcasts."""

import uuid

import pytest

from audioreader.models import Episode, Feed, FeedAlias, Subscription, User

SEARCH_URL = "https://itunes.apple.com/search"
SUBSTACK_URL = "https://substack.com/api/v1/top/search"


@pytest.fixture(autouse=True)
def quiet_substack(respx_mock):
    """Substack is asked on every typed search; most tests want it empty."""

    return respx_mock.get(SUBSTACK_URL).respond(json={"items": []})


def substack(*items: dict) -> dict:
    return {"items": list(items)}


def profile(writer: str, **publication) -> dict:
    return {"type": "profileSearchResults", "results": [{"name": writer, "primaryPublication": publication}]}


def post(**publication) -> dict:
    return {"type": "post", "publication": publication}


CONSTRUCTION_PHYSICS = {
    "id": 104058,
    "name": "Construction Physics",
    "subdomain": "constructionphysics",
    "custom_domain": "www.construction-physics.com",
    "logo_url": "https://substackcdn.com/logo.png",
}


async def written_feed(session, url: str, title: str, *, followed: bool = True, audio: bool = False) -> Feed:
    feed = Feed(url=url, title=title)
    feed.episodes.append(
        Episode(
            guid=f"{url}#1",
            title="A post",
            audio_url="https://cdn.example.com/1.mp3" if audio else None,
            content_html=None if audio else "<p>Words.</p>",
        )
    )
    session.add(feed)
    await session.flush()
    if followed:
        # Someone else's subscription: the catalogue is shared.
        other = User(display_name="Another listener", id=uuid.uuid4())
        session.add(other)
        await session.flush()
        session.add(Subscription(user_id=other.id, feed_id=feed.id))
    await session.commit()
    return feed


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


class TestPublicationSearch:
    async def test_finds_a_substack_newsletter_by_name(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Creepy"), show("Curious Cases", "https://f.example/cc")))
        quiet_substack.respond(
            json=substack(
                profile("Brian Potter", **CONSTRUCTION_PHYSICS),
                post(id=2, name="Physics Explained", subdomain="physicsexplained"),
            )
        )

        body = (await client.get("/search/podcasts", params={"q": "Construction physics"})).json()

        assert body[0] == {
            "title": "Construction Physics",
            "feed_url": "https://www.construction-physics.com/feed",
            "publisher": "Brian Potter",
            "artwork_url": "https://substackcdn.com/logo.png",
            "kind": "publication",
        }
        # Substack's loosely related writers are noise; Apple's loose
        # podcasts stay, below the publication that was actually named.
        assert [row["title"] for row in body[1:]] == ["Creepy", "Curious Cases"]
        assert all("kind" not in row for row in body[1:])

    async def test_substack_is_asked_without_platform_words(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        await client.get("/search/podcasts", params={"q": "construction physics substack"})
        assert quiet_substack.calls.last.request.url.params["query"] == "construction physics"

    async def test_finds_written_feeds_other_listeners_follow(self, client, respx_mock, session):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        await written_feed(session, "https://notes.example.com/feed", "Notes on Progress")
        await written_feed(session, "https://ghost.example.com/feed", "Notes nobody follows", followed=False)
        await written_feed(session, "https://audio.example.com/feed", "Notes in audio", audio=True)
        await written_feed(session, "https://paid.example.com/feed?token=secret", "Notes for subscribers")

        body = (await client.get("/search/podcasts", params={"q": "notes"})).json()

        assert body == [
            {"title": "Notes on Progress", "feed_url": "https://notes.example.com/feed", "kind": "publication"}
        ]

    async def test_one_row_when_substack_and_the_catalogue_list_the_same_feed(
        self, client, respx_mock, quiet_substack, session
    ):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        quiet_substack.respond(json=substack(profile("Brian Potter", **CONSTRUCTION_PHYSICS)))
        # Followed before it moved to its own domain: the catalogue knows the
        # substack.com address as its URL and the custom domain as an alias.
        feed = await written_feed(session, "https://constructionphysics.substack.com/feed", "Construction Physics")
        session.add(FeedAlias(url="http://www.construction-physics.com/feed", feed_id=feed.id))
        await session.commit()

        body = (await client.get("/search/podcasts", params={"q": "construction physics"})).json()

        assert len(body) == 1
        assert body[0]["publisher"] == "Brian Potter"

    async def test_one_row_when_apple_and_substack_list_the_same_feed(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(
            json=itunes(show("Construction Physics", "http://www.construction-physics.com/feed"))
        )
        quiet_substack.respond(json=substack(profile("Brian Potter", **CONSTRUCTION_PHYSICS)))

        body = (await client.get("/search/podcasts", params={"q": "construction physics"})).json()

        assert len(body) == 1

    async def test_substack_outage_still_returns_podcasts(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Rest Is History")))
        quiet_substack.respond(status_code=503)

        response = await client.get("/search/podcasts", params={"q": "rest is history"})

        assert response.status_code == 200
        assert [row["title"] for row in response.json()] == ["The Rest Is History"]

    async def test_apple_outage_still_returns_publications(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        quiet_substack.respond(json=substack(profile("Brian Potter", **CONSTRUCTION_PHYSICS)))

        response = await client.get("/search/podcasts", params={"q": "construction physics"})

        assert response.status_code == 200
        assert response.json()[0]["kind"] == "publication"

    async def test_malformed_substack_rows_are_skipped(self, client, respx_mock, quiet_substack):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        quiet_substack.respond(
            json=substack(
                post(id="not a number", name="Construction Physics"),
                post(id=3, name="Construction Physics", subdomain="bad host!"),
                {"type": "profileSearchResults", "results": ["nonsense", {"name": "x"}]},
                profile("Brian Potter", **CONSTRUCTION_PHYSICS),
            )
        )

        body = (await client.get("/search/podcasts", params={"q": "construction physics"})).json()

        assert [row["feed_url"] for row in body] == ["https://www.construction-physics.com/feed"]


class TestPublicationWebSearch:
    async def test_explicit_web_search_returns_a_verified_feed(self, client, fake_llm, respx_mock, article_xml):
        feed_url = "https://notesonprogress.example.com/feed"
        fake_llm.respond_with({"publication": "Notes on Progress", "urls": [feed_url]})
        respx_mock.get(feed_url).respond(content=article_xml, content_type="application/rss+xml")

        response = await client.post("/search/publications", json={"query": "Notes on Progress"})

        assert response.status_code == 200
        assert response.json()["feed_url"] == feed_url
        assert response.json()["title"] == "Notes on Progress"

    async def test_web_search_requires_current_ai_permission(self, client, fake_llm, user):
        user.ai_consent_version = None
        user.ai_data_sharing_consented_at = None

        response = await client.post("/search/publications", json={"query": "Notes on Progress"})

        assert response.status_code == 403
        assert fake_llm.calls == []
