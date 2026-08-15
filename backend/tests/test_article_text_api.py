"""GET /episodes/{id}/text: the reading path for written articles."""

from sqlalchemy import select

from audioreader.feeds import articles
from audioreader.models import Episode, Feed

FEED_URL = "https://example.com/feed.xml"

ARTICLE_PAGE = b"""
<html><head><title>Why sewers made cities possible</title></head><body>
<article>
<h1>Why sewers made cities possible</h1>
<p>For most of history, cities were death traps. The concentration of people
brought a concentration of waste, and with it cholera, typhoid and dysentery
on a scale the countryside never knew.</p>
<p>The Victorian sewer changed that arithmetic completely. Once waste could be
carried away faster than it accumulated, the city stopped killing its
inhabitants faster than it attracted them, and urban growth became compounding
rather than self-limiting.</p>
<p>This essay traces how that happened, and why it took so long.</p>
</article>
</body></html>
"""


async def subscribe(client, respx_mock, xml: bytes, url: str = FEED_URL):
    respx_mock.get(url).respond(content=xml, content_type="application/rss+xml")
    return await client.post("/feeds", json={"url": url})


class TestHasText:
    async def test_article_episodes_are_marked_readable(self, client, respx_mock, article_xml):
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episodes = (await client.get(f"/feeds/{feed_id}/episodes")).json()
        assert all(e["audio_url"] is None for e in episodes)
        assert all(e["has_text"] is True for e in episodes)


class TestEpisodeText:
    async def test_full_feed_content_is_used_without_fetching(self, client, respx_mock, article_xml, monkeypatch):
        # Below the threshold the endpoint would try the page; a Substack-style
        # feed with the whole article inline must never need the network.
        monkeypatch.setattr(articles, "FULL_TEXT_THRESHOLD", 10)
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]

        response = await client.get(f"/episodes/{episode['id']}/text")

        assert response.status_code == 200
        body = response.json()
        assert body["title"] == "Why sewers made cities possible"
        assert "For most of history, cities were death traps" in body["text"]

    async def test_teaser_feeds_fall_back_to_the_article_page(self, client, respx_mock, article_xml):
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]
        page = respx_mock.get("https://notesonprogress.example.com/p/sewers").respond(
            content=ARTICLE_PAGE, content_type="text/html"
        )

        response = await client.get(f"/episodes/{episode['id']}/text")

        assert response.status_code == 200
        assert page.call_count == 1
        text = response.json()["text"]
        assert "Victorian sewer" in text
        # Paragraphs arrive separated by blank lines for the app to chunk on.
        assert "\n\n" in text

    async def test_text_is_cached_after_first_read(self, client, respx_mock, article_xml):
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]
        page = respx_mock.get("https://notesonprogress.example.com/p/sewers").respond(
            content=ARTICLE_PAGE, content_type="text/html"
        )

        first = (await client.get(f"/episodes/{episode['id']}/text")).json()["text"]
        second = (await client.get(f"/episodes/{episode['id']}/text")).json()["text"]

        assert first == second
        assert page.call_count == 1

    async def test_unreachable_page_still_reads_the_feed_content(self, client, respx_mock, article_xml):
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]
        respx_mock.get("https://notesonprogress.example.com/p/sewers").respond(status_code=500)

        response = await client.get(f"/episodes/{episode['id']}/text")

        assert response.status_code == 200
        assert "For most of history" in response.json()["text"]

    async def test_unknown_episode_is_404(self, client):
        assert (await client.get("/episodes/9999/text")).status_code == 404

    async def test_episode_with_nothing_to_read_is_422_with_spoken_error(self, client, session):
        feed = Feed(url="https://bare.example.com/feed", title="Bare")
        feed.episodes.append(Episode(guid="bare-1", title="Silent"))
        session.add(feed)
        await session.commit()
        episode = await session.scalar(select(Episode).where(Episode.guid == "bare-1"))

        response = await client.get(f"/episodes/{episode.id}/text")

        assert response.status_code == 422
        assert "spoken_response" in response.json()["detail"]
