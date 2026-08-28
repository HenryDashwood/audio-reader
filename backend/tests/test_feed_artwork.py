from datetime import UTC, datetime, timedelta

from audioreader.feeds.artwork import SITE_ARTWORK_RECHECK_AFTER, artwork_url_in_html, site_artwork_is_due

PAGE_URL = "https://publication.example.com/articles/"


class TestArtworkURLInHTML:
    def test_prefers_open_graph_over_twitter_and_icons(self):
        html = """
        <html><head>
        <meta name="twitter:image" content="/twitter.jpg">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" href="/favicon.ico">
        <meta property="og:image" content="/social-card.jpg">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) == "https://publication.example.com/social-card.jpg"

    def test_uses_a_raster_icon_and_respects_the_base_element(self):
        html = """
        <html><head>
        <base href="https://cdn.example.com/assets/">
        <link rel="icon" type="image/svg+xml" href="mark.svg">
        <link rel="shortcut icon" href="favicon.png">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) == "https://cdn.example.com/assets/favicon.png"

    def test_ignores_images_in_body_content(self):
        html = """
        <html><head><title>Publication</title></head><body>
        <meta property="og:image" content="https://attacker.example/image.jpg">
        <link rel="icon" href="https://attacker.example/icon.png">
        </body></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) is None

    def test_rejects_non_web_and_credentialed_urls(self):
        html = """
        <html><head>
        <meta property="og:image" content="data:image/png;base64,abc">
        <link rel="icon" href="https://user:password@example.com/icon.png">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) is None


class TestSiteArtworkSchedule:
    def test_never_checked_is_due(self):
        assert site_artwork_is_due(None)

    def test_recent_check_is_not_due_but_old_check_is(self):
        now = datetime(2026, 8, 28, tzinfo=UTC)

        assert not site_artwork_is_due(now - timedelta(days=1), now=now)
        assert site_artwork_is_due(now - SITE_ARTWORK_RECHECK_AFTER, now=now)
