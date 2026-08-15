"""Cleanup of catalog entries that were ingested for a preview and forgotten."""

from datetime import timedelta

import pytest
from sqlalchemy import select

from audioreader.config import settings
from audioreader.feeds import service
from audioreader.feeds.poller import prune_orphaned_feeds
from audioreader.models import Episode, Feed, PlaybackPosition, utcnow
from audioreader.positions import upsert_position

FEED_URL = "https://example.com/feed.xml"


@pytest.fixture
def long_ago():
    return utcnow() - timedelta(days=settings.orphan_feed_retention_days + 1)


async def ingested_feed(session, respx_mock, xml: bytes, url: str = FEED_URL) -> Feed:
    """A feed in the catalog that nobody subscribes to — what previewing a
    show, or playing one episode of it, leaves behind."""
    respx_mock.get(url).respond(content=xml)
    return await service.ensure_feed(session, url)


async def age(session, feed: Feed, when) -> None:
    feed.created_at = when
    await session.commit()


class TestPruneOrphanedFeeds:
    async def test_removes_an_old_unsubscribed_feed(self, session, respx_mock, podcast_xml, long_ago):
        feed = await ingested_feed(session, respx_mock, podcast_xml)
        await age(session, feed, long_ago)

        assert await prune_orphaned_feeds(session) == 1
        assert await session.get(Feed, feed.id) is None

    async def test_removes_its_episodes_too(self, session, respx_mock, podcast_xml, long_ago):
        feed = await ingested_feed(session, respx_mock, podcast_xml)
        await age(session, feed, long_ago)

        await prune_orphaned_feeds(session)

        remaining = (await session.scalars(select(Episode))).all()
        assert remaining == []

    async def test_keeps_a_subscribed_feed(self, session, user, respx_mock, podcast_xml, long_ago):
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        feed = await service.subscribe(session, FEED_URL, user)
        await age(session, feed, long_ago)

        assert await prune_orphaned_feeds(session) == 0
        assert await session.get(Feed, feed.id) is not None

    async def test_keeps_a_feed_she_has_listened_to(self, session, user, respx_mock, podcast_xml, long_ago):
        # Playing one episode without subscribing is a supported path; her
        # position in it must not be deleted out from under her.
        feed = await ingested_feed(session, respx_mock, podcast_xml)
        episode = await session.scalar(select(Episode).limit(1))
        await upsert_position(session, user, episode.id, 120.0, completed=False)
        await age(session, feed, long_ago)

        assert await prune_orphaned_feeds(session) == 0
        assert await session.get(Feed, feed.id) is not None

    async def test_keeps_a_recently_previewed_feed(self, session, respx_mock, podcast_xml):
        # She is probably looking at it right now.
        feed = await ingested_feed(session, respx_mock, podcast_xml)

        assert await prune_orphaned_feeds(session) == 0
        assert await session.get(Feed, feed.id) is not None

    async def test_leaves_positions_of_other_feeds_alone(
        self, session, user, respx_mock, podcast_xml, article_xml, long_ago
    ):
        kept = await ingested_feed(session, respx_mock, podcast_xml)
        episode = await session.scalar(select(Episode).limit(1))
        await upsert_position(session, user, episode.id, 30.0, completed=False)
        dropped = await ingested_feed(session, respx_mock, article_xml, url="https://example.com/other.xml")
        await age(session, kept, long_ago)
        await age(session, dropped, long_ago)

        assert await prune_orphaned_feeds(session) == 1
        assert await session.get(Feed, kept.id) is not None
        assert await session.get(Feed, dropped.id) is None
        assert await session.get(PlaybackPosition, (user.id, episode.id)) is not None

    async def test_batch_size_caps_one_pass(
        self, session, respx_mock, podcast_xml, article_xml, long_ago, monkeypatch
    ):
        monkeypatch.setattr(settings, "orphan_prune_batch_size", 1)
        first = await ingested_feed(session, respx_mock, podcast_xml)
        second = await ingested_feed(session, respx_mock, article_xml, url="https://example.com/other.xml")
        await age(session, first, long_ago)
        await age(session, second, long_ago)

        assert await prune_orphaned_feeds(session) == 1
        assert await prune_orphaned_feeds(session) == 1
        assert await prune_orphaned_feeds(session) == 0
