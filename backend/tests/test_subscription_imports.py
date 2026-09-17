import asyncio
from datetime import timedelta
from pathlib import Path

import pytest
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import async_sessionmaker

from audioreader.feeds import service as feeds
from audioreader.feeds.fetcher import FeedFetchError, FeedRateLimitedError
from audioreader.imports import service
from audioreader.models import (
    Episode,
    Feed,
    Subscription,
    User,
    utcnow,
)
from audioreader.models import (
    SubscriptionImport as Job,
)
from audioreader.models import (
    SubscriptionImportItem as Item,
)
from audioreader.models import (
    SubscriptionImportLease as Lease,
)

FIXTURE = (Path(__file__).parent / "fixtures/opml/mixed.opml").read_bytes()


async def preview(client):
    reply = await client.post(
        "/subscription-imports/preview", content=FIXTURE, headers={"Content-Type": "application/xml"}
    )
    assert reply.status_code == 200, reply.text
    return reply.json()


async def start(client, job, ids=None, request_id="start-1"):
    return await client.post(
        f"/subscription-imports/{job['id']}/start",
        json={
            "entry_ids": ids if ids is not None else [row["id"] for row in job["items"] if row["status"] == "ready"],
            "request_id": request_id,
            "public_feeds_confirmed": True,
        },
    )


async def ready(session):
    await session.execute(update(Lease).values(until=utcnow() - timedelta(seconds=1)))
    await session.execute(update(Item).values(next_attempt_at=utcnow() - timedelta(seconds=1)))
    await session.commit()


@pytest.fixture
def maker(session):
    return async_sessionmaker(session.bind, expire_on_commit=False)


@pytest.fixture
def fake_feeds(monkeypatch):
    async def prepare(session, url):
        feed = await session.scalar(select(Feed).where(Feed.url == url))
        if feed is None:
            feed = Feed(url=url, title="Imported feed")
            session.add(feed)
            await session.flush()
            session.add(Episode(feed_id=feed.id, guid=url, title="Existing episode"))
            await session.commit()
        return feed

    monkeypatch.setattr(feeds, "ensure_feed", prepare)
    return prepare


async def test_preview_has_no_side_effects_and_start_is_idempotent(client, session):
    job = await preview(client)
    assert job["duplicates"] == 1
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 0
    assert await session.scalar(select(func.count()).select_from(Feed)) == 0
    reply = await start(client, job)
    assert reply.status_code == 202, reply.text
    assert reply.json()["total"] == 2
    assert (await start(client, job)).json() == reply.json()
    assert (await start(client, job, ids=[job["items"][0]["id"]])).status_code == 409


async def test_requires_public_review_and_valid_selection(client):
    job = await preview(client)
    url = f"/subscription-imports/{job['id']}/start"
    assert (await client.post(url, json={"request_id": "x", "entry_ids": [job["items"][0]["id"]]})).status_code == 422
    assert (await start(client, job, ids=[job["items"][-1]["id"]])).status_code == 422
    assert (await start(client, job, ids=[999999])).status_code == 422


async def test_worker_keeps_receipt_atomic_and_latest_clean(client, session, user, maker, fake_feeds):
    job = await preview(client)
    assert (await start(client, job)).status_code == 202
    assert await service.process_one(maker)
    await ready(session)
    assert await service.process_one(maker)
    reply = (await client.get(f"/subscription-imports/{job['id']}")).json()
    assert (reply["status"], reply["added"], reply["finished"]) == ("completed", 2, 2)
    subscriptions = list(await session.scalars(select(Subscription)))
    assert len(subscriptions) == 2
    assert all(row.latest_after_episode_id is not None for row in subscriptions)
    # A receipt survives deliberate unfollow: recovering old work must not follow again.
    await feeds.unsubscribe(session, subscriptions[0].feed_id, user)
    await ready(session)
    assert not await service.process_one(maker)
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 1
    assert (await start(client, job)).json()["status"] == "completed"


async def test_stop_before_or_during_fetch(client, session, maker, fake_feeds, monkeypatch):
    job = await preview(client)
    await start(client, job)
    began, resume = asyncio.Event(), asyncio.Event()

    async def paused(session, url):
        began.set()
        await resume.wait()
        return await fake_feeds(session, url)

    monkeypatch.setattr(feeds, "ensure_feed", paused)
    task = asyncio.create_task(service.process_one(maker))
    await asyncio.wait_for(began.wait(), 2)
    stopped = await client.post(f"/subscription-imports/{job['id']}/stop")
    assert stopped.json()["not_imported"] == 2
    resume.set()
    await task
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 0
    assert (await client.post(f"/subscription-imports/{job['id']}/stop")).json()["status"] == "stopped"


async def test_restart_recovers_processing_item_and_lease_fences_workers(client, session, maker, fake_feeds):
    job = await preview(client)
    await start(client, job)
    await session.execute(update(Item).where(Item.id == job["items"][0]["id"]).values(status="processing"))
    await session.commit()
    token = await service.claim_lease(session)
    assert token
    assert not await service.process_one(maker)
    await ready(session)
    assert await service.process_one(maker)
    assert (await client.get(f"/subscription-imports/{job['id']}")).json()["added"] == 1


async def test_lost_lease_cannot_commit(client, session, maker, fake_feeds, monkeypatch):
    job = await preview(client)
    await start(client, job)

    async def superseded(db, url):
        feed = await fake_feeds(db, url)
        async with maker() as another:
            await another.execute(update(Lease).values(token="new-owner"))
            await another.commit()
        return feed

    monkeypatch.setattr(feeds, "ensure_feed", superseded)
    assert not await service.process_one(maker)
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 0


async def test_failures_are_independent_retry_only_failures(client, session, maker, fake_feeds, monkeypatch):
    job = await preview(client)
    await start(client, job)

    async def sometimes(db, url):
        if "publication" in url:
            raise FeedFetchError("private text must not be exposed")
        return await fake_feeds(db, url)

    monkeypatch.setattr(feeds, "ensure_feed", sometimes)
    for _ in range(4):
        await ready(session)
        assert await service.process_one(maker)
    result = (await client.get(f"/subscription-imports/{job['id']}")).json()
    assert (result["status"], result["added"], result["failed"]) == ("completed", 1, 1)
    assert "private text" not in str(result)
    retried = await client.post(f"/subscription-imports/{job['id']}/retry", json={"request_id": "retry-1"})
    assert retried.status_code == 202, retried.text
    assert retried.json()["total"] == 1
    assert (
        await client.post(f"/subscription-imports/{job['id']}/retry", json={"request_id": "retry-1"})
    ).json() == retried.json()
    monkeypatch.setattr(feeds, "ensure_feed", fake_feeds)
    await ready(session)
    assert await service.process_one(maker)
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 2


async def test_cross_account_and_expiry(client, session, make_client):
    job = await preview(client)
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as stranger:
        assert (await stranger.get(f"/subscription-imports/{job['id']}")).status_code == 404
        assert (await stranger.post(f"/subscription-imports/{job['id']}/stop")).status_code == 404
        assert (await stranger.get("/subscription-imports/current")).json() is None
    await session.execute(update(Job).values(expires_at=utcnow() - timedelta(seconds=1)))
    await session.commit()
    assert (await client.get(f"/subscription-imports/{job['id']}")).status_code == 404
    await service.cleanup(session)
    assert await session.scalar(select(func.count()).select_from(Item)) == 0


async def test_existing_subscription_and_alias_not_selected(client, session, user):
    from audioreader.models import FeedAlias

    feed = Feed(url="https://original.example/feed", title="Existing")
    session.add(feed)
    await session.flush()
    session.add_all(
        [
            Subscription(user_id=user.id, feed_id=feed.id, latest_after_episode_id=42),
            FeedAlias(feed_id=feed.id, url="https://podcast.example/feed"),
        ]
    )
    await session.commit()
    job = await preview(client)
    assert job["items"][0]["status"] == "already_following"
    assert (await start(client, job)).json()["total"] == 1
    assert (await session.scalar(select(Subscription))).latest_after_episode_id == 42


async def test_one_active_job_and_preview_size(client, session, user):
    first = await preview(client)
    # Clone a second draft to exercise database enforcement independently of preview.
    clone = Job(user_id=(await session.get(Job, first["id"])).user_id, expires_at=utcnow() + timedelta(days=1))
    session.add(clone)
    await session.flush()
    item = Item(
        job_id=clone.id, ordinal=0, title="Other", host="other.example", url="https://other.example", status="ready"
    )
    session.add(item)
    await session.commit()
    await start(client, first)
    assert (await start(client, {"id": clone.id}, ids=[item.id], request_id="second")).status_code == 409
    # The shared test-session auth fixture was expired by the intentional rollback.
    await session.refresh(user)
    assert (
        await client.post("/subscription-imports/preview", content=b"x" * (5 * 1024 * 1024 + 1))
    ).status_code == 413


async def test_publisher_delay_is_honoured(client, session, maker, monkeypatch):
    job = await preview(client)
    await start(client, job)

    async def throttled(*_):
        raise FeedRateLimitedError("wait", retry_after_seconds=3600)

    monkeypatch.setattr(feeds, "ensure_feed", throttled)
    assert await service.process_one(maker)
    assert not await service.process_one(maker)
    row = await session.get(Lease, 1)
    assert row.until.replace(tzinfo=utcnow().tzinfo) > utcnow() + timedelta(minutes=59)


async def test_real_feed_pipeline_redirects_and_mixed_sources(
    client, session, maker, respx_mock, podcast_xml, article_xml
):
    raw = b"""<opml><body>
      <outline xmlUrl="https://old.example/feed"/>
      <outline xmlUrl="https://podcast.example/canonical"/>
      <outline xmlUrl="https://publication.example/feed"/>
    </body></opml>"""
    respx_mock.get("https://old.example/feed").respond(301, headers={"Location": "https://podcast.example/canonical"})
    respx_mock.get("https://podcast.example/canonical").respond(
        content=podcast_xml, content_type="application/rss+xml"
    )
    respx_mock.get("https://publication.example/feed").respond(content=article_xml, content_type="application/rss+xml")
    respx_mock.get("https://notesonprogress.example.com/").respond(404)
    job = (await client.post("/subscription-imports/preview", content=raw)).json()
    assert not respx_mock.calls
    await start(client, job)
    for _ in range(3):
        await ready(session)
        assert await service.process_one(maker)
    result = (await client.get(f"/subscription-imports/{job['id']}")).json()
    assert (result["added"], result["already_following"], result["failed"]) == (2, 1, 0)
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 2
    assert sum(feed["is_article_feed"] for feed in (await client.get("/feeds")).json()) == 1


async def test_redirect_to_private_network_is_rejected(client, session, maker, respx_mock):
    job = (
        await client.post(
            "/subscription-imports/preview",
            content=b'<opml><body><outline xmlUrl="https://public.example/feed"/></body></opml>',
        )
    ).json()
    respx_mock.get("https://public.example/feed").respond(302, headers={"Location": "http://127.0.0.1/private"})
    await start(client, job)
    for _ in range(3):
        await ready(session)
        await service.process_one(maker)
    result = (await client.get(f"/subscription-imports/{job['id']}")).json()
    assert result["failed"] == 1
    assert all(call.request.url.host == "public.example" for call in respx_mock.calls)
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 0


@pytest.mark.parametrize("delay", [float("inf"), 1e100, 86401])
async def test_unbounded_publisher_hint_cannot_break_worker(client, session, maker, monkeypatch, delay):
    job = await preview(client)
    await start(client, job)

    async def throttled(*_):
        raise FeedRateLimitedError("wait", retry_after_seconds=delay)

    monkeypatch.setattr(feeds, "ensure_feed", throttled)
    assert await service.process_one(maker)
    result = (await client.get(f"/subscription-imports/{job['id']}")).json()
    assert result["failed"] == 1
    assert not result["items"][0]["retryable"]
    lease = await session.get(Lease, 1)
    assert lease.until.replace(tzinfo=utcnow().tzinfo) < utcnow() + timedelta(seconds=5)
