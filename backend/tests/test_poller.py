from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy import select

from audioreader.config import settings
from audioreader.feeds import poller, service
from audioreader.feeds.poller import feed_is_failing, poll_all_feeds, poll_feed, poll_lock
from audioreader.models import Episode, utcnow

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
    async def test_adds_only_new_episodes(self, session, user, respx_mock, podcast_xml, podcast_updated_xml):
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

    async def test_advances_last_polled_at(self, session, user, respx_mock, podcast_xml, podcast_updated_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        subscribed_at = feed.last_polled_at
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        await poll_feed(session, feed)

        assert feed.last_polled_at is not None
        assert subscribed_at is not None
        assert feed.last_polled_at > subscribed_at

    async def test_refreshes_feed_metadata(self, session, user, respx_mock, podcast_xml, podcast_updated_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        await poll_feed(session, feed)

        assert feed.description == "A weekly podcast about history, now with bonus episodes."

    async def test_stores_cache_validators(self, session, user, respx_mock, podcast_xml, podcast_updated_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(
            content=podcast_updated_xml,
            headers={"ETag": '"feed-v2"', "Last-Modified": "Wed, 19 Aug 2026 20:00:00 GMT"},
        )

        await poll_feed(session, feed)

        assert feed.etag == '"feed-v2"'
        assert feed.last_modified == "Wed, 19 Aug 2026 20:00:00 GMT"

    async def test_not_modified_is_a_successful_conditional_poll(self, session, user, respx_mock, podcast_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        previous_poll = feed.last_polled_at
        feed.etag = '"feed-v1"'
        feed.last_modified = "Tue, 18 Aug 2026 20:00:00 GMT"
        feed.consecutive_failures = 6
        feed.last_error = "temporary failure"
        await session.commit()
        response = respx_mock.get(FEED_URL).respond(status_code=304)

        assert await poll_feed(session, feed) == 0

        assert response.calls.last.request.headers["if-none-match"] == '"feed-v1"'
        assert response.calls.last.request.headers["if-modified-since"] == "Tue, 18 Aug 2026 20:00:00 GMT"
        assert feed.last_polled_at is not None
        assert previous_poll is not None
        assert feed.last_polled_at > previous_poll
        assert feed.consecutive_failures == 0
        assert feed.last_error is None

    async def test_not_modified_feed_gains_website_artwork_after_upgrade(self, session, user, respx_mock, article_xml):
        site_url = "https://notesonprogress.example.com/"
        respx_mock.get(site_url).respond(content=b"<html><head></head></html>", content_type="text/html")
        feed = await subscribed_feed(session, user, respx_mock, article_xml)
        # Existing rows receive NULL in the new migration, so their next poll
        # performs the first website metadata check even when the feed is 304.
        feed.image_url = None
        feed.site_image_url = None
        feed.site_artwork_checked_at = None
        await session.commit()

        artwork = f"{site_url}social-card.jpg"
        respx_mock.get(FEED_URL).respond(status_code=304)
        respx_mock.get(site_url).respond(
            content=f'<html><head><meta property="og:image" content="{artwork}"></head></html>',
            content_type="text/html",
        )

        assert await poll_feed(session, feed) == 0
        assert feed.site_image_url == artwork
        assert feed.site_artwork_checked_at is not None

    async def test_poll_preserves_website_artwork_when_feed_still_has_none(
        self, session, user, respx_mock, article_xml
    ):
        site_url = "https://notesonprogress.example.com/"
        artwork = f"{site_url}social-card.jpg"
        site = respx_mock.get(site_url).respond(
            content=f'<html><head><meta property="og:image" content="{artwork}"></head></html>',
            content_type="text/html",
        )
        feed = await subscribed_feed(session, user, respx_mock, article_xml)
        respx_mock.get(FEED_URL).respond(content=article_xml, content_type="application/rss+xml")

        await poll_feed(session, feed)

        assert feed.image_url is None
        assert feed.site_image_url == artwork
        assert site.call_count == 1


class TestPollAllFeeds:
    async def test_polls_every_feed(self, session, user, respx_mock, podcast_xml, article_xml, podcast_updated_xml):
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)
        respx_mock.get(OTHER_URL).respond(content=article_xml)

        summary = await poll_all_feeds(session)

        assert summary.polled == 2
        assert summary.failed == 0
        assert summary.episodes_added == 1

    async def test_one_failing_feed_does_not_block_others(self, session, user, respx_mock, podcast_xml, article_xml):
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(OTHER_URL).respond(status_code=500)
        respx_mock.get(FEED_URL).respond(content=(FIXTURES / "podcast_feed_updated.xml").read_bytes())

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


class TestFailureTracking:
    async def test_a_failed_poll_is_counted(self, session, user, respx_mock, podcast_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=500)

        await poll_all_feeds(session)

        await session.refresh(feed)
        assert feed.consecutive_failures == 1
        assert feed.last_error

    async def test_failures_accumulate(self, session, user, respx_mock, podcast_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=500)

        for _ in range(3):
            await poll_all_feeds(session)

        await session.refresh(feed)
        assert feed.consecutive_failures == 3

    async def test_a_successful_poll_clears_the_count(
        self, session, user, respx_mock, podcast_xml, podcast_updated_xml
    ):
        # A feed that was briefly unreachable must not stay flagged forever.
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=500)
        await poll_all_feeds(session)

        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)
        await poll_all_feeds(session)

        await session.refresh(feed)
        assert feed.consecutive_failures == 0
        assert feed.last_error is None

    async def test_persistent_failure_is_reported(self, session, user, respx_mock, podcast_xml, monkeypatch):
        monkeypatch.setattr(settings, "feed_failure_threshold", 2)
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=500)

        assert (await poll_all_feeds(session)).failing == ()
        assert (await poll_all_feeds(session)).failing == (feed.title,)

    async def test_a_failing_feed_does_not_stop_the_pass(
        self, session, user, respx_mock, podcast_xml, article_xml, monkeypatch
    ):
        monkeypatch.setattr(settings, "feed_failure_threshold", 1)
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(OTHER_URL).respond(status_code=500)
        respx_mock.get(FEED_URL).respond(content=podcast_xml)

        summary = await poll_all_feeds(session)

        assert summary.failed == 1
        assert summary.polled == 1


def aware(moment: datetime | None) -> datetime:
    # SQLite hands back naive datetimes for timezone-aware columns.
    assert moment is not None
    return moment if moment.tzinfo is not None else moment.replace(tzinfo=UTC)


class TestThrottling:
    """A 429 is the site asking for a pause, not a feed that has broken."""

    async def test_a_throttle_is_not_held_against_the_feed(self, session, user, respx_mock, podcast_xml):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "60"})

        summary = await poll_all_feeds(session)

        assert summary.failed == 1
        assert summary.throttled == 1
        await session.refresh(feed)
        assert feed.consecutive_failures == 0
        assert feed.last_error
        assert feed.throttled_until is not None

    async def test_a_throttled_feed_is_left_alone(self, session, user, respx_mock, podcast_xml):
        # Asking again fifteen minutes later, like every other feed, is what
        # keeps the throttle going.
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        route = respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "60"})
        # respx keeps one route per pattern, history included: the subscribe
        # fetch is already on it.
        fetched_so_far = route.call_count

        await poll_all_feeds(session)
        summary = await poll_all_feeds(session)

        assert route.call_count == fetched_so_far + 1
        assert summary.polled == 0
        assert summary.failed == 0

    async def test_our_floor_wins_over_a_short_hint(self, session, user, respx_mock, podcast_xml, monkeypatch):
        monkeypatch.setattr(settings, "feed_throttle_backoff_seconds", 3600)
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "60"})
        before = utcnow()

        await poll_all_feeds(session)

        await session.refresh(feed)
        assert aware(feed.throttled_until) >= before + timedelta(seconds=3600)

    async def test_the_sites_hint_wins_when_longer(self, session, user, respx_mock, podcast_xml, monkeypatch):
        monkeypatch.setattr(settings, "feed_throttle_backoff_seconds", 60)
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "7200"})
        before = utcnow()

        await poll_all_feeds(session)

        await session.refresh(feed)
        assert aware(feed.throttled_until) >= before + timedelta(seconds=7200)

    async def test_no_hint_means_the_floor(self, session, user, respx_mock, podcast_xml, monkeypatch):
        monkeypatch.setattr(settings, "feed_throttle_backoff_seconds", 1800)
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        respx_mock.get(FEED_URL).respond(status_code=429)
        before = utcnow()

        await poll_all_feeds(session)

        await session.refresh(feed)
        assert aware(feed.throttled_until) >= before + timedelta(seconds=1800)

    async def test_a_throttle_expires_and_success_clears_it(
        self, session, user, respx_mock, podcast_xml, podcast_updated_xml
    ):
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        feed.throttled_until = utcnow() - timedelta(minutes=1)
        feed.last_error = "the site temporarily limited Magpie's feed requests"
        await session.commit()
        respx_mock.get(FEED_URL).respond(content=podcast_updated_xml)

        summary = await poll_all_feeds(session)

        assert summary.polled == 1
        await session.refresh(feed)
        assert feed.throttled_until is None
        assert feed.last_error is None

    async def test_a_feed_throttled_for_days_is_failing(self, session, user, respx_mock, podcast_xml, monkeypatch):
        monkeypatch.setattr(settings, "feed_stale_after_days", 3)
        feed = await subscribed_feed(session, user, respx_mock, podcast_xml)
        feed.last_error = "the site temporarily limited Magpie's feed requests"

        # An evening's throttling is nothing to tell her about...
        feed.last_polled_at = utcnow() - timedelta(hours=2)
        assert not feed_is_failing(feed)

        # ...days of it is a feed that is not updating, whatever the reason.
        feed.last_polled_at = utcnow() - timedelta(days=4)
        assert feed_is_failing(feed)

        # A feed that merely has nothing new is not failing at all.
        feed.last_error = None
        assert not feed_is_failing(feed)


class TestPacing:
    """A pass reaches a shared host as a trickle, not a burst."""

    async def paced_pass(self, session, user, respx_mock, podcast_xml, article_xml, monkeypatch, **kwargs):
        await subscribed_feed(session, user, respx_mock, podcast_xml)
        await subscribed_feed(session, user, respx_mock, article_xml, url=OTHER_URL)
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        respx_mock.get(OTHER_URL).respond(content=article_xml)
        sleeps: list[float] = []

        async def record(seconds: float) -> None:
            sleeps.append(seconds)

        monkeypatch.setattr(poller, "asyncio", SimpleNamespace(sleep=record))
        await poll_all_feeds(session, **kwargs)
        return sleeps

    async def test_feeds_are_spaced_out(self, session, user, respx_mock, podcast_xml, article_xml, monkeypatch):
        sleeps = await self.paced_pass(
            session, user, respx_mock, podcast_xml, article_xml, monkeypatch, spacing_seconds=2.5
        )
        # One gap between two feeds: nothing before the first, nothing after the last.
        assert sleeps == [2.5]

    async def test_pacing_takes_at_most_half_the_interval(
        self, session, user, respx_mock, podcast_xml, article_xml, monkeypatch
    ):
        monkeypatch.setattr(settings, "poll_interval_seconds", 8)
        sleeps = await self.paced_pass(
            session, user, respx_mock, podcast_xml, article_xml, monkeypatch, spacing_seconds=10
        )
        assert sleeps == [2.0]

    async def test_no_spacing_by_default(self, session, user, respx_mock, podcast_xml, article_xml, monkeypatch):
        sleeps = await self.paced_pass(session, user, respx_mock, podcast_xml, article_xml, monkeypatch)
        assert sleeps == []


class TestPollLock:
    async def test_sqlite_always_gets_the_lock(self, session):
        # Nothing to coordinate outside Postgres; the poller must not become a
        # no-op in development because of a lock that cannot exist.
        async with poll_lock(session) as acquired:
            assert acquired is True

    async def test_the_lock_is_released_even_if_the_pass_raises(self, session):
        with pytest.raises(RuntimeError):
            async with poll_lock(session) as acquired:
                assert acquired
                raise RuntimeError("poll blew up")

        async with poll_lock(session) as acquired:
            assert acquired is True
