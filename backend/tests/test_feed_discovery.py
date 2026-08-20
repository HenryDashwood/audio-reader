"""Pasting a homepage must work as well as pasting the feed itself."""

from audioreader.feeds.discovery import feed_links_in_html

SITE_URL = "https://notesonprogress.example.com"
FEED_URL = "https://notesonprogress.example.com/feed"
APPLE_LOOKUP_URL = "https://itunes.apple.com/lookup"

HOMEPAGE = b"""
<html><head>
<title>Notes on Progress</title>
<link rel="stylesheet" href="/style.css">
<link rel="alternate" type="application/rss+xml" title="RSS" href="/feed">
</head><body>Essays.</body></html>
"""

HOMEPAGE_NO_LINK = b"<html><head><title>Notes on Progress</title></head><body>Essays.</body></html>"


class TestFeedLinksInHtml:
    def test_finds_and_absolutises_advertised_feeds(self):
        links = feed_links_in_html(HOMEPAGE.decode(), base_url=SITE_URL)
        assert links == [FEED_URL]

    def test_ignores_stylesheets_and_pages_without_feeds(self):
        assert feed_links_in_html(HOMEPAGE_NO_LINK.decode(), base_url=SITE_URL) == []

    def test_atom_and_absolute_urls_accepted(self):
        html = '<link rel="alternate" type="application/atom+xml" href="https://x.test/atom.xml">'
        assert feed_links_in_html(html, base_url=SITE_URL) == ["https://x.test/atom.xml"]

    def test_broken_markup_does_not_raise(self):
        assert feed_links_in_html("<link rel=<<<>>", base_url=SITE_URL) == []


class TestSubscribeByHomepage:
    async def test_link_tag_discovery(self, client, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        response = await client.post("/feeds", json={"url": SITE_URL})

        assert response.status_code == 201
        body = response.json()
        assert body["title"] == "Notes on Progress"
        # The catalog stores the real feed URL, not the homepage.
        assert body["url"] == FEED_URL

    async def test_common_path_fallback(self, client, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE_NO_LINK, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.route().respond(status_code=404)

        response = await client.post("/feeds", json={"url": SITE_URL})

        assert response.status_code == 201
        assert response.json()["url"] == FEED_URL

    async def test_homepage_and_feed_url_are_one_catalog_entry(self, client, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        by_feed = await client.post("/feeds/preview", json={"url": FEED_URL})
        by_homepage = await client.post("/feeds/preview", json={"url": SITE_URL})

        assert by_feed.json()["feed"]["id"] == by_homepage.json()["feed"]["id"]

    async def test_relative_feed_links_resolve_against_the_redirected_host(self, client, respx_mock, article_xml):
        # astralcodexten.com redirects to www., and its '/feed' link only
        # exists on the www host. The relative link must resolve against
        # where the page actually came from, not what was typed.
        apex = "https://acx.example.com"
        www = "https://www.acx.example.com"
        respx_mock.get(f"{apex}/").respond(status_code=301, headers={"Location": f"{www}/"})
        respx_mock.get(f"{www}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(f"{www}/feed").respond(content=article_xml, content_type="application/rss+xml")

        response = await client.post("/feeds", json={"url": apex})

        assert response.status_code == 201
        assert response.json()["url"] == f"{www}/feed"

    async def test_subscribing_twice_via_homepage_conflicts(self, client, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        assert (await client.post("/feeds", json={"url": SITE_URL})).status_code == 201
        assert (await client.post("/feeds", json={"url": SITE_URL})).status_code == 409

    async def test_an_apple_podcasts_share_link_resolves_to_its_feed(self, client, respx_mock, podcast_xml):
        shared = "https://podcasts.apple.com/gb/podcast/the-history-hour/id123456789?i=987654321"
        podcast_feed = "https://feeds.example.com/history-hour.xml"
        lookup = respx_mock.get(APPLE_LOOKUP_URL).respond(
            json={
                "resultCount": 1,
                "results": [
                    {
                        "collectionId": 123456789,
                        "collectionName": "The History Hour",
                        "feedUrl": podcast_feed,
                    }
                ],
            }
        )
        respx_mock.get(podcast_feed).respond(content=podcast_xml, content_type="application/rss+xml")

        response = await client.post("/feeds/preview", json={"url": shared})

        assert response.status_code == 200
        assert response.json()["feed"]["url"] == podcast_feed
        assert lookup.calls.last.request.url.params["id"] == "123456789"
        assert lookup.calls.last.request.url.params["country"] == "gb"
