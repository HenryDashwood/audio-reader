from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select, update

from audioreader.feeds import poller, service
from audioreader.models import Episode, Feed, FeedAlias, utcnow

FEED_URL = "https://example.com/feed.xml"
SITE_URL = "https://example.com/"
TRANSCRIPT = "The interviewer and guest discuss a newly published research project. " * 30


@pytest.fixture
def updated_article_xml(article_xml):
    item = f"""<item>
      <title>A new interview</title>
      <guid isPermaLink="false">new-interview</guid>
      <link>https://example.com/new-interview</link>
      <pubDate>Fri, 04 Sep 2026 10:00:00 GMT</pubDate>
      <content:encoded><![CDATA[<p>{TRANSCRIPT}</p>]]></content:encoded>
    </item>""".encode()
    return article_xml.replace(b"<item>", item + b"<item>", 1)


async def old_preview(client, session, respx_mock, xml):
    respx_mock.get(FEED_URL).respond(content=xml, content_type="application/rss+xml")
    first = await client.post("/feeds/preview", json={"url": FEED_URL})
    assert first.status_code == 200
    feed = await session.get(Feed, first.json()["feed"]["id"])
    feed.last_polled_at = utcnow() - timedelta(days=4)
    await session.commit()
    return feed, first.json()


@pytest.mark.parametrize("address", ["feed", "known_alias", "new_homepage"])
async def test_reopening_an_unsubscribed_preview_imports_new_posts_and_keeps_progress(
    client, session, respx_mock, article_xml, updated_article_xml, address
):
    feed, first = await old_preview(client, session, respx_mock, article_xml)
    original_id = first["episodes"][0]["id"]
    await client.put(f"/episodes/{original_id}/position", json={"position_seconds": 18.0})
    original = await session.get(Episode, original_id)
    original.article_text = "An already extracted article body."
    await session.commit()
    url = FEED_URL
    if address == "known_alias":
        session.add(FeedAlias(url=SITE_URL, feed_id=feed.id))
        await session.commit()
        url = SITE_URL
    elif address == "new_homepage":
        respx_mock.get(SITE_URL).respond(
            content=f'<html><head><link rel="alternate" type="application/rss+xml" href="{FEED_URL}"></head></html>',
            content_type="text/html",
        )
        url = SITE_URL
    route = respx_mock.get(FEED_URL).respond(content=updated_article_xml, content_type="application/rss+xml")

    reopened = await client.post("/feeds/preview", json={"url": url})

    assert reopened.status_code == 200
    body = reopened.json()
    assert body["subscribed"] is False
    assert body["feed"]["id"] == feed.id
    assert body["feed"]["episode_count"] == 3
    assert body["episodes"][0]["title"] == "A new interview"
    assert body["episodes"][0]["has_text"] is True
    assert {e["id"] for e in first["episodes"]}.issubset({e["id"] for e in body["episodes"]})
    assert next(e for e in body["episodes"] if e["id"] == original_id)["position_seconds"] == 18.0
    await session.refresh(original)
    assert original.article_text == "An already extracted article body."
    interview = await session.get(Episode, body["episodes"][0]["id"])
    assert TRANSCRIPT in interview.content_html
    assert (await client.get("/feeds")).json() == []
    fetched = route.call_count
    again = await client.post("/feeds/preview", json={"url": url})
    assert again.json()["feed"]["episode_count"] == 3
    assert route.call_count == fetched


async def test_subscribing_to_a_stale_preview_refreshes_before_setting_latest_cursor(
    client, session, respx_mock, article_xml, updated_article_xml
):
    feed, _ = await old_preview(client, session, respx_mock, article_xml)
    respx_mock.get(FEED_URL).respond(content=updated_article_xml)

    response = await client.post("/feeds", json={"url": FEED_URL})

    assert response.status_code == 201
    assert response.json()["id"] == feed.id
    assert response.json()["episode_count"] == 3
    assert (await client.get("/episodes")).json() == []


async def test_a_preview_with_no_success_timestamp_is_refreshed(
    client, session, respx_mock, article_xml, updated_article_xml
):
    feed, _ = await old_preview(client, session, respx_mock, article_xml)
    feed.last_polled_at = None
    await session.commit()
    respx_mock.get(FEED_URL).respond(content=updated_article_xml)

    response = await client.post("/feeds/preview", json={"url": FEED_URL})

    assert response.json()["episodes"][0]["title"] == "A new interview"
    await session.refresh(feed)
    assert feed.last_polled_at is not None


async def test_unchanged_preview_uses_validators_and_clears_failure_state(client, session, respx_mock, podcast_xml):
    feed, first = await old_preview(client, session, respx_mock, podcast_xml)
    feed.etag = '"cached-feed"'
    feed.last_modified = "Wed, 02 Sep 2026 10:00:00 GMT"
    feed.consecutive_failures = 4
    feed.last_error = "previous failure"
    feed.throttled_until = utcnow() - timedelta(seconds=1)
    await session.commit()
    route = respx_mock.get(FEED_URL).respond(status_code=304)
    before = utcnow()

    response = await client.post("/feeds/preview", json={"url": FEED_URL})

    assert response.status_code == 200
    assert episode_snapshot(response.json()) == episode_snapshot(first)
    assert route.calls.last.request.headers["if-none-match"] == '"cached-feed"'
    assert route.calls.last.request.headers["if-modified-since"] == feed.last_modified
    await session.refresh(feed)
    assert aware(feed.last_polled_at) >= before
    assert feed.consecutive_failures == 0
    assert feed.last_error is None
    assert feed.throttled_until is None


@pytest.mark.parametrize("status,content", [(500, b"unavailable"), (200, b"not a feed")])
async def test_failed_refresh_keeps_cached_posts_and_backs_off(
    client, session, respx_mock, podcast_xml, status, content
):
    feed, first = await old_preview(client, session, respx_mock, podcast_xml)
    last_success = aware(feed.last_polled_at)
    route = respx_mock.get(FEED_URL).respond(status_code=status, content=content)
    fetched = route.call_count
    before = utcnow()

    response = await client.post("/feeds/preview", json={"url": FEED_URL})
    again = await client.post("/feeds/preview", json={"url": FEED_URL})

    assert response.status_code == again.status_code == 200
    assert episode_snapshot(response.json()) == episode_snapshot(again.json()) == episode_snapshot(first)
    assert route.call_count == fetched + 1
    await session.refresh(feed)
    assert aware(feed.last_polled_at) == last_success
    assert feed.consecutive_failures == 1
    assert feed.last_error
    assert aware(feed.throttled_until) >= before + poller.CATALOG_REFRESH_INTERVAL

    feed.throttled_until = utcnow() - timedelta(seconds=1)
    await session.commit()
    route.respond(content=podcast_xml)
    recovered = await client.post("/feeds/preview", json={"url": FEED_URL})
    assert recovered.status_code == 200
    await session.refresh(feed)
    assert feed.consecutive_failures == 0
    assert feed.last_error is None
    assert feed.throttled_until is None


async def test_preview_honours_publisher_retry_after_and_skips_artwork_during_backoff(
    client, session, respx_mock, article_xml
):
    feed, first = await old_preview(client, session, respx_mock, article_xml)
    feed.site_artwork_checked_at = None
    await session.commit()
    site = respx_mock.get("https://notesonprogress.example.com/").respond(content=b"<html></html>")
    site_calls = site.call_count
    route = respx_mock.get(FEED_URL).respond(status_code=429, headers={"Retry-After": "7200"})
    fetched = route.call_count
    before = utcnow()

    response = await client.post("/feeds/preview", json={"url": FEED_URL})
    again = await client.post("/feeds/preview", json={"url": FEED_URL})

    assert response.status_code == again.status_code == 200
    assert episode_snapshot(response.json()) == episode_snapshot(first)
    assert route.call_count == fetched + 1
    assert site.call_count == site_calls
    await session.refresh(feed)
    assert feed.consecutive_failures == 0
    assert aware(feed.throttled_until) >= before + timedelta(hours=2)


@pytest.mark.parametrize("already_updated", ["last_polled_at", "throttled_until"])
async def test_refresh_rechecks_database_state_after_another_request_finishes(
    session, respx_mock, podcast_xml, already_updated
):
    route = respx_mock.get(FEED_URL).respond(content=podcast_xml)
    feed = await service.ensure_feed(session, FEED_URL)
    feed.last_polled_at = utcnow() - timedelta(days=4)
    await session.commit()
    # Keep the request's ORM object stale while the row changes, as when a
    # background poll or another preview finishes before this request's lock.
    value = utcnow() if already_updated == "last_polled_at" else utcnow() + timedelta(hours=1)
    await session.execute(
        update(Feed)
        .where(Feed.id == feed.id)
        .values({already_updated: value})
        .execution_options(synchronize_session=False)
    )
    await session.commit()

    await poller.refresh_stale_feed(session, feed)

    assert route.call_count == 1
    assert len((await session.scalars(select(Episode).where(Episode.feed_id == feed.id))).all()) == 3


def aware(moment: datetime | None) -> datetime:
    assert moment is not None
    return moment if moment.tzinfo is not None else moment.replace(tzinfo=UTC)


def episode_snapshot(body):
    # In-memory SQLite drops UTC offsets when an episode is reloaded; compare
    # the represented instant, as well as all its other stored/display fields.
    return [
        {
            **episode,
            "published_at": aware(datetime.fromisoformat(episode["published_at"])).isoformat()
            if episode["published_at"]
            else None,
        }
        for episode in body["episodes"]
    ]
