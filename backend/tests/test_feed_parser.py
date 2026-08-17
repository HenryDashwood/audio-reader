from datetime import UTC, datetime
from pathlib import Path

import pytest

from audioreader.feeds.parser import FeedParseError, parse_feed

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def podcast_xml() -> bytes:
    return (FIXTURES / "podcast_feed.xml").read_bytes()


@pytest.fixture
def article_xml() -> bytes:
    return (FIXTURES / "article_feed.xml").read_bytes()


class TestPodcastFeed:
    def test_parses_feed_metadata(self, podcast_xml):
        feed = parse_feed(podcast_xml)
        assert feed.title == "The History Hour"
        assert feed.description == "A weekly podcast about history."
        assert feed.image_url == "https://example.com/historyhour/cover.jpg"

    def test_parses_all_items(self, podcast_xml):
        feed = parse_feed(podcast_xml)
        assert len(feed.items) == 3
        assert feed.items[0].title == "The Fall of Constantinople"

    def test_item_fields(self, podcast_xml):
        item = parse_feed(podcast_xml).items[0]
        assert item.guid == "hh-ep-103"
        assert item.audio_url == "https://cdn.example.com/hh/103.mp3"
        assert item.description == "With guest Professor Maria Sharpe on the siege of 1453."
        assert item.published_at == datetime(2026, 7, 28, 5, 0, 0, tzinfo=UTC)

    def test_duration_hh_mm_ss_format(self, podcast_xml):
        assert parse_feed(podcast_xml).items[0].duration_seconds == 3723

    def test_duration_plain_seconds_format(self, podcast_xml):
        assert parse_feed(podcast_xml).items[1].duration_seconds == 3125

    def test_missing_duration_is_none(self, podcast_xml):
        assert parse_feed(podcast_xml).items[2].duration_seconds is None

    def test_missing_guid_falls_back_to_link(self, podcast_xml):
        # The trailer item has no <guid>; we still need a stable identifier
        # so re-polling the feed does not duplicate episodes.
        assert parse_feed(podcast_xml).items[2].guid == "https://example.com/historyhour/trailer-4"

    def test_item_level_artwork_is_captured(self, podcast_xml):
        assert parse_feed(podcast_xml).items[0].image_url == ("https://example.com/historyhour/ep103.jpg")

    def test_item_without_artwork_is_none(self, podcast_xml):
        # No item-level image: the API falls back to the show's artwork.
        assert parse_feed(podcast_xml).items[1].image_url is None

    def test_a_name_is_taken_out_of_the_rss_author_mailbox(self, podcast_xml):
        # <author> is specified as an address with the name in brackets after
        # it. The name is the byline; the address is not.
        assert parse_feed(podcast_xml).items[0].author == "Nadia Rahman"

    def test_an_item_with_no_author_takes_the_channel_s(self, podcast_xml):
        assert parse_feed(podcast_xml).items[1].author == "The History Hour team"


class TestArticleFeed:
    def test_items_have_no_audio(self, article_xml):
        feed = parse_feed(article_xml)
        assert len(feed.items) == 2
        assert all(item.audio_url is None for item in feed.items)

    def test_items_carry_html_content(self, article_xml):
        item = parse_feed(article_xml).items[0]
        assert item.content_html is not None
        assert "death traps" in item.content_html

    def test_the_writer_is_captured_for_the_byline(self, article_xml):
        assert parse_feed(article_xml).items[0].author == "Ada Whitfield"

    def test_a_bare_mailbox_is_not_a_byline(self, article_xml):
        # The channel names only <managingEditor>, an address. The second item
        # names nobody, so it has no author at all rather than an email one.
        feed = parse_feed(article_xml)
        assert feed.author is None
        assert feed.items[1].author is None


class TestInvalidInput:
    def test_not_a_feed_raises(self):
        with pytest.raises(FeedParseError):
            parse_feed(b"<html><body>This is not a feed</body></html>")

    def test_empty_input_raises(self):
        with pytest.raises(FeedParseError):
            parse_feed(b"")
