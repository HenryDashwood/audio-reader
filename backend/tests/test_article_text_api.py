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


#: A feed that ships the whole article inline, with the markup a reader wants:
#: a heading, emphasis, a link and a picture, none of which reach speech.
RICH_FEED = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Rich</title>
    <link>https://rich.example.com</link>
    <item>
      <title>An illustrated piece</title>
      <guid isPermaLink="true">https://rich.example.com/p/one</guid>
      <link>https://rich.example.com/p/one</link>
      <content:encoded><![CDATA[<h2>A heading</h2>
        <p>Prose with <strong>emphasis</strong> and a
        <a href="/elsewhere" onclick="steal()">link</a>.</p>
        <figure><img src="/pictures/one.png" alt="A picture"><figcaption>A caption</figcaption></figure>
        <script>steal()</script>
        <iframe src="https://tracker.example.com"></iframe>]]></content:encoded>
    </item>
  </channel>
</rss>
"""


class TestArticleHtml:
    async def test_markup_survives_for_the_reader(self, client, respx_mock, monkeypatch):
        monkeypatch.setattr(articles, "FULL_TEXT_THRESHOLD", 10)
        feed_id = (await subscribe(client, respx_mock, RICH_FEED, "https://rich.example.com/feed.xml")).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]

        html = (await client.get(f"/episodes/{episode['id']}/text")).json()["html"]

        assert "<h2>A heading</h2>" in html
        assert "<strong>emphasis</strong>" in html
        assert "<img" in html and 'src="/pictures/one.png"' in html
        # Relative, as the feed wrote it — the app renders against the
        # article's own URL as base, which is what resolves it.
        assert 'href="/elsewhere"' in html

    async def test_scripts_and_frames_are_stripped(self, client, respx_mock, monkeypatch):
        # This markup is rendered in a web view. Whatever a blog serves, what
        # reaches the phone is structure and prose.
        monkeypatch.setattr(articles, "FULL_TEXT_THRESHOLD", 10)
        feed_id = (await subscribe(client, respx_mock, RICH_FEED, "https://rich.example.com/feed.xml")).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]

        html = (await client.get(f"/episodes/{episode['id']}/text")).json()["html"]

        assert "<script" not in html
        assert "<iframe" not in html
        assert "onclick" not in html
        assert "steal()" not in html

    async def test_the_spoken_text_is_unchanged_by_the_markup(self, client, respx_mock, monkeypatch):
        monkeypatch.setattr(articles, "FULL_TEXT_THRESHOLD", 10)
        feed_id = (await subscribe(client, respx_mock, RICH_FEED, "https://rich.example.com/feed.xml")).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]

        text = (await client.get(f"/episodes/{episode['id']}/text")).json()["text"]

        assert "<" not in text
        assert "A heading" in text
        assert "Prose with emphasis" in text
        assert "link." in text

    async def test_html_is_cached_with_the_text(self, client, respx_mock, article_xml):
        # One fetch between reading and listening, not one each.
        feed_id = (await subscribe(client, respx_mock, article_xml)).json()["id"]
        episode = (await client.get(f"/feeds/{feed_id}/episodes")).json()[0]
        page = respx_mock.get("https://notesonprogress.example.com/p/sewers").respond(
            content=ARTICLE_PAGE, content_type="text/html"
        )

        first = (await client.get(f"/episodes/{episode['id']}/text")).json()
        second = (await client.get(f"/episodes/{episode['id']}/text")).json()

        assert page.call_count == 1
        assert first["html"] == second["html"]
        assert "<p>" in first["html"]

    async def test_an_article_read_before_the_column_existed_keeps_its_text(self, client, session, monkeypatch):
        monkeypatch.setattr(articles, "FULL_TEXT_THRESHOLD", 10)
        # Rows cached by an older version have text and no HTML. The text must
        # survive verbatim: the player's timeline is estimated from it, and a
        # re-extraction that shifted it would move saved positions.
        feed = Feed(url="https://old.example.com/feed", title="Old")
        feed.episodes.append(
            Episode(
                guid="old-1",
                title="Read last year",
                link="https://old.example.com/p/one",
                content_html="<p>Some words that were extracted long ago.</p>",
                article_text="Words as they were first extracted.",
            )
        )
        session.add(feed)
        await session.commit()
        episode = await session.scalar(select(Episode).where(Episode.guid == "old-1"))

        body = (await client.get(f"/episodes/{episode.id}/text")).json()

        assert body["text"] == "Words as they were first extracted."
        assert "<p>" in body["html"]
