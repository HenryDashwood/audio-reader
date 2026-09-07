from datetime import timedelta

import pytest
from sqlalchemy import func, select

from audioreader import saved
from audioreader.auth.service import delete_user
from audioreader.feeds import service
from audioreader.feeds.poller import prune_orphaned_feeds
from audioreader.models import (
    ArticleContent,
    Episode,
    Feed,
    PlaybackPosition,
    SavedArticle,
    Subscription,
    User,
    utcnow,
)

URL = "https://example.com/essay"


def page(title="Private essay", text="The original private words"):
    paragraphs = "".join(
        f"<p>{text}. This paragraph explains the subject in enough detail to be a useful article, "
        "with evidence and examples for the reader.</p>"
        for _ in range(8)
    )
    return (
        f"<html><head><title>{title}</title></head><body><article><h1>{title}</h1>{paragraphs}</article></body></html>"
    )


async def capture(client, **fields):
    response = await client.post("/saved", json={"url": URL, "html": page(), **fields})
    assert response.status_code == 200, response.text
    return response.json()


async def test_standalone_capture_is_private_and_does_not_subscribe(client, session, make_client):
    item = await capture(client)
    assert item["content_id"] and item["saved_at"] and item["has_text"]
    assert (await session.get(Episode, item["id"])).feed_id is None
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 0
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as outsider:
        assert (await outsider.get("/saved")).json() == []
        for suffix in ("", "/text", f"/text?content_id={item['content_id']}"):
            assert (await outsider.get(f"/episodes/{item['id']}{suffix}")).status_code == 404
        assert (
            await outsider.put(f"/episodes/{item['id']}/position", json={"position_seconds": 10})
        ).status_code == 404
        assert (await outsider.put(f"/episodes/{item['id']}/state", json={"played": True})).status_code == 404
        assert (await outsider.get("/search/episodes", params={"q": "Private"})).json() == []


async def test_multiple_private_captures_keep_selection_and_progress(client, session):
    first = await capture(client)
    response = await client.put(
        f"/episodes/{first['id']}/position", json={"position_seconds": 42, "content_id": first["content_id"]}
    )
    assert response.status_code == 204
    second = await capture(client, html=page(text="Completely changed words"))
    assert second["id"] == first["id"]
    assert second["content_id"] == first["content_id"]
    assert second["position_seconds"] == 42
    assert await session.scalar(select(func.count()).select_from(ArticleContent)) == 2
    third = await capture(client, html=page(text="Completely changed words"))
    assert third["content_id"] == first["content_id"]
    assert await session.scalar(select(func.count()).select_from(ArticleContent)) == 2
    body = (await client.get(f"/episodes/{first['id']}/text")).json()
    assert "original private words" in body["text"]
    other_id = await session.scalar(select(ArticleContent.id).where(ArticleContent.id != first["content_id"]))
    assert (
        await client.put(f"/episodes/{first['id']}/position", json={"position_seconds": 99, "content_id": other_id})
    ).status_code == 409
    # An old client's unversioned tick cannot overwrite the selected copy.
    await client.put(f"/episodes/{first['id']}/position", json={"position_seconds": 100})
    assert (await client.get(f"/episodes/{first['id']}")).json()["position_seconds"] == 42


async def test_same_url_different_users_never_share_private_text(client, session, make_client):
    first = await capture(client)
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as outsider:
        second = await capture(outsider, html=page(text="The other account words"))
        assert second["id"] == first["id"]
        assert second["content_id"] != first["content_id"]
        response = await outsider.get(f"/episodes/{first['id']}/text?content_id={first['content_id']}")
        assert response.status_code == 404
        assert "other account words" in (await outsider.get(f"/episodes/{first['id']}/text")).json()["text"]


async def test_failed_extraction_keeps_link_then_retry_can_prepare_it(client, respx_mock):
    route = respx_mock.get(URL).respond(503)
    response = await client.post("/saved", json={"url": URL})
    assert response.status_code == 200
    item = response.json()
    assert item["capture_error"] and not item["has_text"]
    assert (await client.get(f"/episodes/{item['id']}/text")).status_code == 422
    route.respond(200, text=page(), content_type="text/html")
    response = await client.post(f"/saved/{item['id']}/retry")
    assert response.status_code == 200
    assert response.json()["content_id"] and response.json()["capture_error"] is None


@pytest.mark.parametrize("status", [401, 403])
async def test_refused_web_fetch_recovers_by_sharing_browser_content(client, respx_mock, status):
    route = respx_mock.get(URL).respond(status)
    response = await client.post("/saved", json={"url": URL})
    assert response.status_code == 200
    item = response.json()
    assert "refused Magpie's request" in item["capture_error"]
    assert "Safari" in item["capture_error"]
    assert not item["has_text"] and item["content_id"] is None

    # Safari shares its loaded page; this must repair the existing link without
    # another server fetch, a duplicate Saved item, or a changed save date.
    repaired = await capture(client)
    assert route.call_count == 1
    assert repaired["id"] == item["id"]
    assert repaired["saved_at"] == item["saved_at"]
    assert repaired["has_text"] and repaired["content_id"]
    assert repaired["capture_error"] is None
    assert len((await client.get("/saved")).json()) == 1
    text = (await client.get(f"/episodes/{item['id']}/text")).json()["text"]
    assert "original private words" in text


async def test_reconcile_preserves_identity_private_copy_and_position(client, session, user, respx_mock, make_client):
    first = await capture(client)
    await client.put(
        f"/episodes/{first['id']}/position", json={"position_seconds": 42, "content_id": first["content_id"]}
    )
    rss = (
        '<rss version="2.0"><channel><title>Publication</title><link>https://example.com</link>'
        "<description>Essays</description><item><guid>published-1</guid><title>Public title</title>"
        f"<link>{URL}</link><description>A public summary</description></item></channel></rss>"
    )
    respx_mock.get("https://example.com/feed").respond(200, text=rss)
    respx_mock.get("https://example.com/").respond(200, text="<html></html>")
    feed = await service.subscribe(session, "https://example.com/feed", user)
    article = await session.get(Episode, first["id"])
    assert article.feed_id == feed.id
    assert article.title == "Public title"
    assert article.article_text is None
    assert (await client.get(f"/episodes/{first['id']}")).json()["position_seconds"] == 42
    assert "original private words" in (await client.get(f"/episodes/{first['id']}/text")).json()["text"]
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as outsider:
        assert (await outsider.get(f"/episodes/{first['id']}")).json()["title"] == "Public title"
        assert (
            await outsider.get(f"/episodes/{first['id']}/text?content_id={first['content_id']}")
        ).status_code == 404
    await service.unsubscribe(session, feed.id, user)
    feed.created_at = utcnow() - timedelta(days=365)
    await session.commit()
    assert await prune_orphaned_feeds(session) == 0
    assert len((await client.get("/saved")).json()) == 1


async def test_save_existing_preserves_historical_speech_and_progress(client, session, user):
    feed = Feed(url="https://example.com/feed", title="Publication")
    episode = Episode(
        feed=feed, guid="1", title="Essay", article_text="Historical speech", article_html="<p>Historical speech</p>"
    )
    session.add(episode)
    await session.flush()
    session.add(PlaybackPosition(user_id=user.id, episode_id=episode.id, position_seconds=12))
    await session.commit()
    item = (await client.post("/saved", json={"episode_id": episode.id})).json()
    assert item["position_seconds"] == 12
    assert (await client.get(f"/episodes/{episode.id}/text")).json()["text"] == "Historical speech"
    await client.delete(f"/saved/{episode.id}")
    assert (await client.get("/saved")).json() == []
    assert (await client.get(f"/episodes/{episode.id}")).json()["position_seconds"] == 12


async def test_account_deletion_erases_private_snapshots(client, session, user):
    await capture(client)
    await delete_user(session, user)
    assert await session.scalar(select(func.count()).select_from(ArticleContent)) == 0
    assert await session.scalar(select(func.count()).select_from(SavedArticle)) == 0


@pytest.mark.parametrize(
    "url", ["file:///etc/passwd", "https://user:password@example.com/a", "https://example.com:8000/a"]
)
async def test_reject_non_web_or_credential_urls(client, url):
    assert (await client.post("/saved", json={"url": url})).status_code == 422


async def test_content_is_sanitized(client):
    item = await capture(
        client,
        html=page().replace("</article>", '<script>alert(1)</script><a href="javascript:alert(1)">bad</a></article>'),
    )
    html = (await client.get(f"/episodes/{item['id']}/text")).json()["html"]
    assert "<script" not in html and "javascript:" not in html


def test_url_identity_preserves_meaningful_queries():
    assert saved.normalize_url("https://EXAMPLE.com:443/a?token=one#section") == "https://example.com/a?token=one"
    assert saved.normalize_url("https://example.com/a?token=one") != saved.normalize_url(
        "https://example.com/a?token=two"
    )


async def test_saved_titles_are_searchable_by_voice_and_in_app(client, session, user):
    from audioreader.commands import library
    from audioreader.commands import service as commands

    item = await capture(client, title="An unexpected otter")
    results = (await client.get("/search/episodes", params={"q": "otter"})).json()
    assert [row["id"] for row in results] == [item["id"]]
    candidates = await commands.build_candidates(session, user, "read the otter article I saved")
    assert any(c.id == item["id"] and c.title == "An unexpected otter" for c in candidates)
    matches = await library.search(
        session, user, query="otter", unheard=True, kind="article", max_seconds=None, saved_only=True
    )
    assert [c.id for c in matches] == [item["id"]]


async def test_private_episode_cannot_be_injected_into_voice_context(client, session, make_client):
    from audioreader.commands.service import _now_playing

    item = await capture(client)
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    assert await _now_playing(session, item["id"], other) is None


async def test_pruning_a_newsletter_retains_saved_issue(client, session, user):
    from audioreader.newsletters.service import _delete_contents

    feed = Feed(url="email://private", title="Private newsletter", source="email", owner_user_id=user.id)
    episode = Episode(
        feed=feed, guid="1", title="Issue", article_text="Saved issue", article_html="<p>Saved issue</p>"
    )
    session.add(episode)
    await session.commit()
    await client.post("/saved", json={"episode_id": episode.id})
    await _delete_contents(session, feed)
    await session.commit()
    assert (await client.get(f"/episodes/{episode.id}/text")).json()["text"] == "Saved issue"


def test_migration_preserves_existing_article_and_progress():
    import importlib.util
    from pathlib import Path

    import sqlalchemy as sa
    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    migration = Path(__file__).parents[1] / "alembic/versions/c726d310e953_saved_articles.py"
    spec = importlib.util.spec_from_file_location("saved_migration", migration)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.exec_driver_sql("CREATE TABLE users (id CHAR(32) PRIMARY KEY)")
        connection.exec_driver_sql("CREATE TABLE feeds (id INTEGER PRIMARY KEY)")
        connection.exec_driver_sql(
            "CREATE TABLE episodes (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL, "
            "title TEXT, CONSTRAINT fk_episodes_feed_id_feeds FOREIGN KEY (feed_id) "
            "REFERENCES feeds(id) ON DELETE CASCADE)"
        )
        connection.exec_driver_sql(
            "CREATE TABLE playback_positions (user_id CHAR(32), episode_id INTEGER, position_seconds FLOAT, "
            "PRIMARY KEY (user_id, episode_id))"
        )
        connection.exec_driver_sql("INSERT INTO feeds VALUES (1)")
        connection.exec_driver_sql("INSERT INTO episodes VALUES (10, 1, 'Historical article')")
        connection.exec_driver_sql("INSERT INTO playback_positions VALUES ('user', 10, 42)")
        with Operations.context(MigrationContext.configure(connection)):
            module.upgrade()
        assert connection.scalar(sa.text("SELECT title FROM episodes WHERE id=10")) == "Historical article"
        assert connection.scalar(sa.text("SELECT position_seconds FROM playback_positions WHERE episode_id=10")) == 42
        columns = {c["name"]: c for c in sa.inspect(connection).get_columns("episodes")}
        assert columns["feed_id"]["nullable"]
        assert "article_contents" in sa.inspect(connection).get_table_names()
        with Operations.context(MigrationContext.configure(connection)):
            module.downgrade()
        assert not {c["name"]: c for c in sa.inspect(connection).get_columns("episodes")}["feed_id"]["nullable"]


async def test_offline_capture_keeps_original_save_date(client):
    original = (utcnow() - timedelta(days=2)).isoformat()
    item = await capture(client, saved_at=original)
    from datetime import datetime

    assert datetime.fromisoformat(item["saved_at"]) == datetime.fromisoformat(original)


def test_private_capture_validation_does_not_enter_telemetry():
    from types import SimpleNamespace

    from audioreader.telemetry import _request_attributes

    attributes = _request_attributes(
        SimpleNamespace(url=SimpleNamespace(path="/saved")),
        {
            "errors": [
                {
                    "type": "string_too_long",
                    "loc": ["body", "html"],
                    "input": "private words",
                    "ctx": {"value": "private"},
                }
            ]
        },
    )
    assert attributes == {"errors": [{"type": "string_too_long", "loc": ["body", "html"]}]}


def test_short_paywall_interstitial_is_not_a_readable_article():
    html, _ = saved.extract(
        "<html><body><article><h1>The essay</h1><p>Subscribe to continue reading. "
        "Already a subscriber? Sign in to read the full article.</p></article></body></html>",
        browser=True,
    )
    assert html == ""
