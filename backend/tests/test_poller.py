from pathlib import Path

import pytest
from sqlalchemy import select

from audioreader.feeds import service
from audioreader.feeds.poller import poll_all_feeds, poll_feed
from audioreader.models import Episode

FIXTURES = Path(__file__).parent / "fixtures"
FEED_URL = "https://example.com/feed.xml"
OTHER_URL = "https://example.com/other.xml"


@pytest.fixture
def podcast_updated_xml() -> bytes:
    return (FIXTURES / "podcast_feed_updated.xml").read_bytes()


async def subscribed_feed(session, user, respx_mock, xml: bytes, url: str = FEED_URL):
    respx_mock.get(url).respond(content=xml)
    return await service.subscribe(session, url, user)


class TestPollFeed:
    async def test_adds_only_new_episodes(
        self, session, user, respx_mock, podcast_xml, podcast_updated_xml
    ):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        added = await poll_feed(session, feed)

        assert added == 1
        episodes = (await session.scalars(select(Episode))).all()
        assert len(episodes) == 4
        assert {episode.guid for episode in episodes} == {
            "hh-ep-104",
            "hh-ep-103",
            "hh-ep-102",
            "https://example.com/historyhour/trailer-4",
        }

    async def test_unchanged_feed_adds_nothing(self, session, user, respx_mock, podcast_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(content=podcast_xml)

        assert await poll_feed(session, feed) == 0
        assert len((await session.scalars(select(Episode))).all()) == 3

    async def test_advances_last_polled_at(
        self, session, user, respx_mock, podcast_xml, podcast_updated_xml
    ):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        subscribed_at = feed.last_polled_at
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        await poll_feed(session, feed)

        assert feed.last_polled_at is not None
        assert subscribed_at is not None
        assert feed.last_polled_at > subscribed_at

    async def test_refreshes_feed_metadata(
        self, session, user, respx_mock, podcast_xml, podcast_updated_xml
    ):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        await poll_feed(session, feed)

        assert feed.description == "A weekly podcast about history, now with bonus episodes."


class TestPollAllFeeds:
    async def test_polls_every_feed(
        self, session, user, respx_mock, podcast_xml, article_xml, podcast_updated_xml
    ):
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)
        respx_mock.get(OTHER_URL).respond(content=article_xml)

        summary = await poll_all_feeds(session)

        assert summary.polled == 2
        assert summary.failed == 0
        assert summary.episodes_added == 1

    async def test_one_failing_feed_does_not_block_others(
        self, session, user, respx_mock, podcast_xml, article_xml
    ):
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(OTHER_URL).respond(status_code=500)
        respx_mock.get(FEED_URL).respond(
            content=(FIXTURES / "podcast_feed_updated.xml").read_bytes()
        )

        summary = await poll_all_feeds(session)

        assert summary.failed == 1
        assert summary.polled == 1
        assert summary.episodes_added == 1

    async def test_skips_feeds_nobody_subscribes_to(self, session, user, respx_mock, podcast_xml):
        # Unsubscribing leaves the feed in the catalog; polling it forever
        # would be wasted work on feeds nobody is listening to.
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        await service.unsubscribe(session, feed.id, user)

        summary = await poll_all_feeds(session)

        assert summary.polled == 0
        assert summary.failed == 0
