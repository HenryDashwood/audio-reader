"""Pasting a homepage must work as well as pasting the feed itself."""

import asyncio

import httpx
import pytest
from sqlalchemy import func, select

from audioreader.feeds import discovery
from audioreader.feeds.discovery import FeedDiscoveryTimeout, feed_links_in_headers, feed_links_in_html
from audioreader.models import Feed, FeedAlias

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

    def test_relative_links_respect_the_html_base_element(self):
        html = """
        <html><head><base href="https://cdn.example.com/publication/">
        <link rel="alternate" type="application/rss+xml" href="main.xml">
        </head></html>
        """
        assert feed_links_in_html(html, base_url=SITE_URL) == ["https://cdn.example.com/publication/main.xml"]

    def test_link_elements_in_user_generated_body_content_are_ignored(self):
        html = """
        <html><head><title>Safe page</title></head><body>
        <link rel="alternate" type="application/rss+xml" href="https://attacker.example/feed">
        </body></html>
        """
        assert feed_links_in_html(html, base_url=SITE_URL) == []

    def test_http_link_headers_are_supported(self):
        links = feed_links_in_headers(
            (
                '</style.css>; rel="stylesheet", </feed.json>; rel="alternate"; '
                'type="application/feed+json"; title="Main feed"',
            ),
            base_url=SITE_URL,
        )
        assert [link.url for link in links] == [f"{SITE_URL}/feed.json"]
        assert links[0].title == "Main feed"

    def test_generic_json_alternate_is_not_mistaken_for_a_json_feed(self):
        html = """
        <html><head>
        <link rel="alternate" type="application/json" href="/wp-json/wp/v2/pages/5">
        <link rel="alternate" type="application/feed+json" href="/feed.json">
        </head></html>
        """
        assert feed_links_in_html(html, base_url=SITE_URL) == [f"{SITE_URL}/feed.json"]


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

    async def test_reuses_homepage_artwork_while_resolving_its_feed(self, client, respx_mock, article_xml):
        artwork = f"{SITE_URL}/social-card.jpg"
        homepage = HOMEPAGE.replace(
            b"</head>",
            f'<meta property="og:image" content="{artwork}"></head>'.encode(),
        )
        home = respx_mock.get(f"{SITE_URL}/").respond(content=homepage, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        response = await client.post("/feeds", json={"url": SITE_URL})

        assert response.status_code == 201
        assert response.json()["image_url"] == artwork
        assert home.call_count == 1

    async def test_common_path_fallback(self, client, respx_mock, article_xml):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE_NO_LINK, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.route().respond(status_code=404)

        response = await client.post("/feeds", json={"url": SITE_URL})

        assert response.status_code == 201
        assert response.json()["url"] == FEED_URL

    async def test_common_path_fallback_when_homepage_is_blocked(self, client, respx_mock, article_xml):
        homepage = respx_mock.get(f"{SITE_URL}/").respond(status_code=403)
        feed = respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.route().respond(status_code=404)

        response = await client.post("/feeds/discover", json={"url": SITE_URL})

        assert response.status_code == 200
        assert response.json()["candidates"][0]["feed_url"] == FEED_URL
        assert homepage.call_count == 1
        assert feed.call_count == 1

    async def test_blocked_explicit_path_does_not_probe_the_origin(self, client, respx_mock):
        members_url = f"{SITE_URL}/members"
        blocked = respx_mock.get(members_url).respond(status_code=403)

        response = await client.post("/feeds/discover", json={"url": members_url})

        assert response.status_code == 502
        assert response.json()["detail"]["code"] == "site_unreachable"
        assert blocked.call_count == 1
        assert len(respx_mock.calls) == 1

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


class TestRankedDiscovery:
    async def test_same_origin_candidates_are_polite_and_main_feed_is_tried_first(
        self, client, respx_mock, article_xml, monkeypatch
    ):
        monkeypatch.setattr(discovery, "SAME_ORIGIN_PROBE_DELAY_SECONDS", 0)
        comments_url = f"{SITE_URL}/comments/feed/"
        homepage = b"""
        <html><head>
        <link rel="alternate" type="application/rss+xml" title="Comments" href="/comments/feed/">
        <link rel="alternate" type="application/json" href="/wp-json/wp/v2/pages/5">
        <link rel="alternate" type="application/rss+xml" title="Main feed" href="/feed">
        </head><body></body></html>
        """
        request_order: list[str] = []
        active = 0
        max_active = 0

        async def feed_response(request):
            nonlocal active, max_active
            request_order.append(request.url.path)
            active += 1
            max_active = max(max_active, active)
            await asyncio.sleep(0.01)
            active -= 1
            return httpx.Response(200, content=article_xml)

        respx_mock.get(f"{SITE_URL}/").respond(content=homepage, content_type="text/html")
        respx_mock.get(FEED_URL).mock(side_effect=feed_response)
        respx_mock.get(comments_url).mock(side_effect=feed_response)

        response = await client.post("/feeds/discover", json={"url": SITE_URL})

        assert response.status_code == 200
        assert request_order == ["/feed", "/comments/feed/"]
        assert max_active == 1
        assert not any("wp-json" in str(call.request.url) for call in respx_mock.calls)

    async def test_rate_limited_feed_has_a_temporary_error_that_survives_cache(self, client, respx_mock, monkeypatch):
        monkeypatch.setattr("audioreader.feeds.fetcher.MAX_UPSTREAM_RETRIES", 0)
        feed = respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "60"})

        first = await client.post("/feeds/discover", json={"url": FEED_URL})
        second = await client.post("/feeds/discover", json={"url": FEED_URL})

        assert first.status_code == 503
        assert first.json()["detail"]["code"] == "site_rate_limited"
        assert second.status_code == 503
        assert second.json()["detail"]["code"] == "site_rate_limited"
        assert feed.call_count == 1

    async def test_returns_multiple_feeds_without_ingesting_them(self, client, session, respx_mock, article_xml):
        comments_url = f"{SITE_URL}/comments.xml"
        homepage = b"""
        <html><head>
        <link rel="alternate" type="application/rss+xml" title="Comments" href="/comments.xml">
        <link rel="alternate" type="application/rss+xml" title="Main articles" href="/feed">
        </head><body></body></html>
        """
        comments = article_xml.replace(b"Notes on Progress", b"Notes on Progress Comments").replace(
            b"sewers-1", b"comment-1"
        )
        respx_mock.get(f"{SITE_URL}/").respond(content=homepage, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.get(comments_url).respond(content=comments, content_type="application/rss+xml")

        response = await client.post("/feeds/discover", json={"url": SITE_URL})

        assert response.status_code == 200
        candidates = response.json()["candidates"]
        assert [candidate["title"] for candidate in candidates] == [
            "Notes on Progress",
            "Notes on Progress Comments",
        ]
        assert candidates[0]["is_primary"] is True
        assert candidates[1]["is_primary"] is False
        assert await session.scalar(select(func.count()).select_from(Feed)) == 0

    async def test_http_link_header_and_json_feed_discovery(self, client, respx_mock):
        json_url = f"{SITE_URL}/feed.json"
        raw = b"""{
          "version":"https://jsonfeed.org/version/1.1",
          "title":"Notes in JSON",
          "items":[{"id":"one","title":"First note","content_text":"Hello"}]
        }"""
        respx_mock.get(f"{SITE_URL}/").respond(
            content=HOMEPAGE_NO_LINK,
            content_type="text/html",
            headers={"Link": '</feed.json>; rel="alternate"; type="application/feed+json"; title="JSON"'},
        )
        respx_mock.get(json_url).respond(content=raw, content_type="application/feed+json")

        response = await client.post("/feeds/discover", json={"url": SITE_URL})

        assert response.status_code == 200
        candidate = response.json()["candidates"][0]
        assert candidate["feed_url"] == json_url
        assert candidate["format"] == "json"

    async def test_spoken_feed_kind_can_override_the_visual_primary(self, respx_mock, article_xml, podcast_xml):
        podcast_url = f"{SITE_URL}/podcast.xml"
        homepage = b"""
        <html><head>
        <link rel="alternate" type="application/rss+xml" title="Main articles" href="/feed">
        <link rel="alternate" type="application/rss+xml" title="Podcast" href="/podcast.xml">
        </head><body></body></html>
        """
        respx_mock.get(f"{SITE_URL}/").respond(content=homepage, content_type="text/html")
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")
        respx_mock.get(podcast_url).respond(content=podcast_xml, content_type="application/rss+xml")

        resolved, parsed = await discovery.resolve_feed(
            SITE_URL,
            preference="subscribe to the podcast feed",
        )

        assert resolved == podcast_url
        assert parsed.title == "The History Hour"

    async def test_successful_discovery_is_cached(self, client, respx_mock, article_xml):
        homepage = respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE, content_type="text/html")
        feed = respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        assert (await client.post("/feeds/discover", json={"url": SITE_URL})).status_code == 200
        assert (await client.post("/feeds/discover", json={"url": SITE_URL})).status_code == 200

        assert homepage.call_count == 1
        assert feed.call_count == 1

    async def test_no_feed_has_a_specific_speakable_error(self, client, respx_mock):
        respx_mock.get(f"{SITE_URL}/").respond(content=HOMEPAGE_NO_LINK, content_type="text/html")
        respx_mock.route().respond(status_code=404)

        response = await client.post("/feeds/discover", json={"url": SITE_URL})

        assert response.status_code == 422
        assert response.json()["detail"]["code"] == "no_feed_found"
        assert response.json()["detail"]["spoken_response"]

    async def test_total_deadline_is_reported(self, monkeypatch):
        async def never_finishes(_url: str):
            await asyncio.sleep(1)
            return []

        monkeypatch.setattr(discovery, "_discover_uncached", never_finishes)
        monkeypatch.setattr(discovery, "DISCOVERY_DEADLINE_SECONDS", 0.001)

        with pytest.raises(FeedDiscoveryTimeout):
            await discovery.discover_feeds("https://slow.example")


class TestCanonicalFeedIdentity:
    async def test_redirect_and_final_url_share_one_feed_and_record_an_alias(
        self, client, session, respx_mock, article_xml
    ):
        old_url = "https://old.example.com/feed"
        new_url = "https://new.example.com/feed.xml"
        respx_mock.get(old_url).respond(status_code=301, headers={"Location": new_url})
        respx_mock.get(new_url).respond(content=article_xml, content_type="application/rss+xml")

        old = await client.post("/feeds/preview", json={"url": old_url})
        new = await client.post("/feeds/preview", json={"url": new_url})

        assert old.status_code == 200
        assert old.json()["feed"]["url"] == new_url
        assert new.json()["feed"]["id"] == old.json()["feed"]["id"]
        assert await session.scalar(select(func.count()).select_from(Feed)) == 1
        assert await session.scalar(select(FeedAlias.url)) == old_url

    async def test_same_origin_self_link_becomes_canonical(self, client, respx_mock, article_xml):
        alias_url = f"{SITE_URL}/current"
        canonical_url = f"{SITE_URL}/canonical.xml"
        with_self = article_xml.replace(
            b"<channel>",
            (
                b'<channel xmlns:atom="http://www.w3.org/2005/Atom">'
                + f'<atom:link href="{canonical_url}" rel="self" type="application/rss+xml"/>'.encode()
            ),
        )
        respx_mock.get(alias_url).respond(content=with_self, content_type="application/rss+xml")

        response = await client.post("/feeds/preview", json={"url": alias_url})

        assert response.status_code == 200
        assert response.json()["feed"]["url"] == canonical_url
