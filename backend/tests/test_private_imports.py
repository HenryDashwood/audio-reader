"""Privacy boundaries use actual parsing, fetching, polling and authenticated APIs."""

import logging
from pathlib import Path

import pytest
from sqlalchemy import func, select

from audioreader.feeds import discovery, poller, private, service
from audioreader.imports import opml
from audioreader.models import Episode, Feed, FeedAlias, User


def rss(body="Private article", guid="one", self_url="https://publisher.example/feed"):
    return f'''<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Members</title>
      <atom:link rel="self" href="{self_url}"/>
      <item><guid>{guid}</guid><title>{body}</title><link>https://publisher.example/article</link>
      <content:encoded><![CDATA[<p>{body * 90}</p>]]></content:encoded></item>
      </channel></rss>'''.encode()


@pytest.mark.parametrize(
    "url",
    [
        "https://publisher.example/feed?token=synthetic-secret",
        "https://publisher.example/feed?subscriber=synthetic-secret",
        "https://publisher.example/0123456789abcdef0123456789abcdef/rss",
        "https://reader:synthetic-password@publisher.example/feed",
    ],
)
async def test_personal_addresses_import_privately_even_when_advertised(session, user, respx_mock, url, caplog):
    caplog.set_level(logging.INFO)
    caplog.set_level(logging.DEBUG, logger="httpx")
    caplog.set_level(logging.DEBUG, logger="httpcore")
    request_url = url.replace("reader:synthetic-password@", "")
    route = respx_mock.get(request_url).respond(content=rss())
    home = respx_mock.get("https://publisher.example/").respond(
        text=f'<link rel="alternate" type="application/rss+xml" href="{url}">'
    )
    feed = await private.ensure_import_feed(session, url, user.id)
    assert feed.owner_user_id == user.id
    assert feed.private_fetch_url == url
    assert feed.url.startswith("private-rss:")
    assert route.called and not home.called
    assert await session.scalar(select(func.count()).select_from(FeedAlias)) == 0
    assert not discovery._discovery_cache
    assert "synthetic-secret" not in caplog.text
    assert "synthetic-password" not in caplog.text
    assert "0123456789abcdef" not in caplog.text


async def test_public_evidence_allows_sharing_but_plain_unlisted_url_does_not(session, user, respx_mock):
    url = "https://publisher.example/feed"
    respx_mock.get(url).respond(content=rss("Public article"))
    home = respx_mock.get("https://publisher.example/").respond(
        text='<html><head><link rel="alternate" type="application/rss+xml" href="/feed"></head></html>'
    )
    first = await private.ensure_import_feed(session, url, user.id)
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    assert first.owner_user_id is None
    assert await private.ensure_import_feed(session, url, other.id) is first
    home.respond(403)
    unlisted = await private.ensure_import_feed(session, url, user.id)
    assert unlisted.id != first.id and unlisted.owner_user_id == user.id


async def test_private_redirect_and_self_link_never_merge_with_public_content(session, user, respx_mock):
    shared = Feed(url="https://publisher.example/feed", title="Public teaser")
    session.add(shared)
    await session.commit()
    url = "https://publisher.example/member?token=synthetic-secret"
    respx_mock.get(url).respond(302, headers={"Location": shared.url})
    respx_mock.get(shared.url).respond(content=rss())
    feed = await private.ensure_import_feed(session, url, user.id)
    assert feed.id != shared.id
    assert feed.private_fetch_url == url
    assert await service._feed_for_url(session, shared.url) is shared
    assert await service._feed_for_url(session, feed.url) is None
    assert await session.scalar(select(func.count()).select_from(FeedAlias)) == 0
    assert await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == shared.id)) == 0


async def test_private_content_stays_account_scoped_through_polling_and_api(
    session, user, client, make_client, respx_mock
):
    url = "https://publisher.example/feed?token=synthetic-secret"
    route = respx_mock.get(url).respond(content=rss())
    # Public standalone identity with the same article URL must never be adopted.
    standalone = Episode(guid="standalone", title="Public", canonical_url="https://publisher.example/article")
    other = User(display_name="Other")
    session.add_all([standalone, other])
    await session.commit()
    first = await private.ensure_import_feed(session, url, user.id)
    second = await private.ensure_import_feed(session, url, other.id)
    assert first.id != second.id
    assert await private.ensure_import_feed(session, url, user.id) is first
    await service.follow_prepared_feed(session, first, user)
    await service.follow_prepared_feed(session, second, other)
    await session.commit()
    own = await session.scalar(select(Episode).where(Episode.feed_id == first.id))
    theirs = await session.scalar(select(Episode).where(Episode.feed_id == second.id))
    assert own.id != theirs.id != standalone.id
    assert standalone.feed_id is None and standalone.title == "Public"
    response = await client.get(f"/episodes/{own.id}/text")
    assert response.status_code == 200 and "Private article" in response.text
    route.respond(content=rss("New private article", guid="two"))
    await poller.poll_feed(session, first)
    assert await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == first.id)) == 2
    assert await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == second.id)) == 1
    async with make_client(other) as stranger:
        for path in [
            f"/feeds/{first.id}/episodes",
            f"/feeds/{first.id}/sources",
            f"/episodes/{own.id}",
            f"/episodes/{own.id}/text",
        ]:
            assert (await stranger.get(path)).status_code == 404
        results = (await stranger.get("/search/episodes", params={"q": "New private"})).json()
        assert "New private article" not in str(results)
        assert (await stranger.put(f"/episodes/{own.id}/state", json={"completed": True})).status_code == 404
    with pytest.raises(ValueError, match="another account"):
        await service.follow_prepared_feed(session, first, other)
    assert "synthetic-secret" not in (await client.get("/feeds")).text


async def test_basic_auth_not_forwarded_to_another_origin(session, user, respx_mock):
    first = respx_mock.get("https://publisher.example/feed").respond(
        302, headers={"Location": "https://cdn.example/feed"}
    )
    second = respx_mock.get("https://cdn.example/feed").respond(content=rss())
    await private.ensure_import_feed(session, "https://reader:synthetic-password@publisher.example/feed", user.id)
    assert first.calls[0].request.headers["authorization"].startswith("Basic ")
    assert "authorization" not in second.calls[0].request.headers


def test_personal_opml_fixture_preserves_fetch_addresses():
    raw = (Path(__file__).parent / "fixtures/opml/personal-feeds.opml").read_bytes()
    entries = opml.parse(raw).entries
    assert len(entries) == 4
    assert all(entry.status == "ready" and entry.url for entry in entries)


async def test_private_worker_receipt_and_repeat_review(client, session, user, respx_mock):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from audioreader.imports import service as imports

    url = "https://publisher.example/feed?token=synthetic-secret"
    respx_mock.get(url).respond(content=rss())
    raw = f'<opml><body><outline text="Members" xmlUrl="{url}"/></body></opml>'.encode()
    draft = (await client.post("/subscription-imports/preview", content=raw)).json()
    start = await client.post(
        f"/subscription-imports/{draft['id']}/start",
        json={
            "request_id": "without-checkbox",
            "entry_ids": [draft["items"][0]["id"]],
        },
    )
    assert start.status_code == 202
    assert await imports.process_one(async_sessionmaker(session.bind, expire_on_commit=False))
    result = (await client.get(f"/subscription-imports/{draft['id']}")).json()
    assert result["added"] == 1 and result["items"][0]["message"] == "Imported privately"
    feed = await session.get(Feed, result["items"][0]["feed_id"])
    assert feed.owner_user_id == user.id
    again = (await client.post("/subscription-imports/preview", content=raw)).json()
    assert again["items"][0]["status"] == "already_following"


async def test_private_redirect_network_guard(session, user, monkeypatch, respx_mock):
    from audioreader.feeds import fetcher

    async def addresses(host, _port):
        return {"127.0.0.1"} if host == "internal.example" else {"93.184.216.34"}

    monkeypatch.setattr(fetcher, "resolve_host_addresses", addresses)
    respx_mock.get("https://publisher.example/feed?token=synthetic-secret").respond(
        302, headers={"Location": "https://internal.example/feed"}
    )
    forbidden = respx_mock.get("https://internal.example/feed").respond(content=rss())
    with pytest.raises(fetcher.FeedFetchError, match="private or local"):
        await private.ensure_import_feed(session, "https://publisher.example/feed?token=synthetic-secret", user.id)
    assert not forbidden.called


async def test_existing_public_archive_refreshed_before_latest_watermark(session, user, respx_mock):
    from audioreader.models import Subscription

    url = "https://publisher.example/feed"
    route = respx_mock.get(url).respond(content=rss("Older article"))
    respx_mock.get("https://publisher.example/").respond(
        text='<link rel="alternate" type="application/rss+xml" href="/feed">'
    )
    feed = await private.ensure_import_feed(session, url, user.id)
    route.respond(content=rss("Already published", guid="two"))
    assert await private.ensure_import_feed(session, url, user.id) is feed
    await service.follow_prepared_feed(session, feed, user)
    await session.commit()
    latest = await session.scalar(select(func.max(Episode.id)).where(Episode.feed_id == feed.id))
    subscription = await session.scalar(select(Subscription).where(Subscription.user_id == user.id))
    assert subscription.latest_after_episode_id == latest
    assert await session.scalar(select(func.count()).select_from(Episode).where(Episode.feed_id == feed.id)) == 2
