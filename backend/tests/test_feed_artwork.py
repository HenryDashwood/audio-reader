from datetime import UTC, datetime, timedelta

from audioreader.feeds.artwork import SITE_ARTWORK_RECHECK_AFTER, artwork_url_in_html, favicon_url, site_artwork_is_due

PAGE_URL = "https://publication.example.com/articles/"


class TestArtworkURLInHTML:
    def test_article_prefers_share_image_then_twitter_then_icon(self):
        icon = '<link rel="apple-touch-icon" href="/touch.png">'
        twitter = '<meta name="twitter:image" content="/twitter.jpg">'
        og = '<meta property="og:image" content="/article.jpg">'
        for metadata, expected in [
            (og + twitter + icon, "article.jpg"),
            (twitter + icon, "twitter.jpg"),
            (icon, "touch.png"),
        ]:
            assert (
                artwork_url_in_html(metadata, PAGE_URL, prefer_social=True)
                == f"https://publication.example.com/{expected}"
            )

    def test_malformed_and_unsupported_social_images_fall_through(self):
        html = """
        <base href="https://[broken">
        <meta property="og:image" content="https://[broken">
        <meta property="og:image" content="javascript:alert(1)">
        <meta property="og:image" content="/art.svg">
        <meta property="og:image" content="https://user:secret@example.com/art.jpg">
        <meta property="og:image" content="https://example.com:9999/art.jpg">
        <link rel="icon" href="/favicon.png">
        """
        assert artwork_url_in_html(html, PAGE_URL, prefer_social=True) == "https://publication.example.com/favicon.png"

    def test_standard_favicon_drops_article_path_query_and_fragment(self):
        assert favicon_url(PAGE_URL + "story?private=token#heading") == "https://publication.example.com/favicon.ico"
        assert favicon_url("file:///private/story") is None
        assert favicon_url("https://user:secret@example.com/story") is None
        assert favicon_url("https://[broken") is None

    def test_prefers_the_sites_own_square_mark_over_the_social_card(self):
        # A touch icon is drawn for a tile; the social card is as often a
        # photo that illustrated the front page as it is a logo.
        html = """
        <html><head>
        <meta name="twitter:image" content="/twitter.jpg">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" href="/favicon.ico">
        <meta property="og:image" content="/social-card.jpg">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) == "https://publication.example.com/touch.png"

    def test_the_social_card_beats_small_icons(self):
        html = """
        <html><head>
        <link rel="icon" href="/favicon.ico" sizes="48x48">
        <link rel="apple-touch-icon" href="/touch-57.png" sizes="57x57">
        <meta property="og:image" content="/social-card.jpg">
        <meta name="twitter:image" content="/twitter.jpg">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) == "https://publication.example.com/social-card.jpg"

    def test_the_largest_declared_mark_wins(self):
        html = """
        <html><head>
        <link rel="icon" href="/favicon.ico" sizes="48x48">
        <link rel="icon" href="/icon-192.png" sizes="192x192" type="image/png">
        <link rel="apple-touch-icon" href="/apple-180.png" sizes="180x180">
        <meta property="og:image" content="/hero-photo.webp">
        </head></html>
        """

        assert artwork_url_in_html(html, PAGE_URL) == "https://publication.example.com/icon-192.png"

    def test_without_a_mark_or_card_the_favicon_will_do(self):
        html = '<html><head><link rel="icon" href="/favicon.ico" sizes="48x48"></head></html>'

        assert artwork_url_in_html(html, PAGE_URL) == "https://publication.example.com/favicon.ico"

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
