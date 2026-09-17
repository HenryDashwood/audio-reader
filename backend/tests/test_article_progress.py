"""Exact article passages, never a speech engine's rendered seconds."""

import hashlib
from datetime import timedelta

import pytest
from sqlalchemy import select

from audioreader.models import (
    ArticleContent,
    ArticleProgressReceipt,
    Episode,
    Feed,
    PlaybackPosition,
    SavedArticle,
    Subscription,
    User,
    utcnow,
)

TEXT = "First 🌱 café e\u0301.\n\nSecond paragraph with some more words."
OFFSET = len("First 🌱 ".encode("utf-16-le")) // 2


@pytest.fixture
async def article(session, user):
    feed = Feed(url="https://bookmarks.test/feed", title="Reading", site_artwork_checked_at=utcnow())
    session.add(feed)
    await session.flush()
    item = Episode(feed=feed, guid="article", title="Reading", article_text=TEXT, article_html="<p>Text</p>")
    session.add_all([item, Subscription(user_id=user.id, feed_id=feed.id)])
    await session.commit()
    return item


async def current(client, item):
    response = await client.get(f"/episodes/{item.id}/text")
    assert response.status_code == 200
    return response.json()["article_progress"]


def body(progress, **changes):
    return (
        dict(
            request_id="original",
            expected_revision=progress["revision"],
            text_version=progress["text_version"],
            content_id=progress["content_id"],
            offset_utf16=OFFSET,
            completed=False,
        )
        | changes
    )


async def send(client, item, payload):
    return await client.put(f"/episodes/{item.id}/article-progress", json=payload)


async def test_exact_unicode_bookmark_retry_preserves_newer_filing(client, session, user, article):
    initial = await current(client, article)
    assert initial["text_version"] == hashlib.sha256(TEXT.encode()).hexdigest()
    payload = body(initial)
    first = await send(client, article, payload)
    assert first.status_code == 200
    accepted = first.json()
    assert accepted["accepted_revision"] == accepted["progress"]["revision"] != initial["revision"]
    assert accepted["episode"]["article_bookmark"] == {"text_version": initial["text_version"], "offset_utf16": OFFSET}
    assert (await current(client, article))["bookmark"] == accepted["episode"]["article_bookmark"]
    position = await session.get(PlaybackPosition, (user.id, article.id))
    stamp = position.updated_at
    assert (await send(client, article, payload)).json() == accepted
    assert position.updated_at == stamp
    await client.put(f"/episodes/{article.id}/state", json={"played": True, "dismissed": True})
    retry = (await send(client, article, payload)).json()
    assert retry["episode"]["completed"] and retry["episode"]["dismissed"]
    assert retry["accepted_revision"] == accepted["accepted_revision"] != retry["progress"]["revision"]
    assert (await send(client, article, payload | {"offset_utf16": 0})).status_code == 409
    assert len(list(await session.scalars(select(ArticleProgressReceipt)))) == 1


async def test_old_device_write_and_restore_invalidate_bookmark_and_offline_clock(client, article):
    initial = await current(client, article)
    first = (await send(client, article, body(initial))).json()
    await client.put(f"/episodes/{article.id}/position", json={"position_seconds": 42, "completed": False})
    newer = await current(client, article)
    assert newer["bookmark"] is None
    assert (await send(client, article, body(first["progress"], request_id="late"))).status_code == 409
    assert (await client.get(f"/episodes/{article.id}")).json()["position_seconds"] == 42
    assert (await send(client, article, body(newer, request_id="fresh"))).status_code == 200
    await client.put(f"/episodes/{article.id}/state", json={"played": False})
    assert (await current(client, article))["bookmark"] is None


async def test_invalid_utf16_boundaries_numbers_and_audio_are_rejected(client, article, session):
    payload = body(await current(client, article))
    for offset in (-1, 7, 10_000, 1.5, True):
        assert (await send(client, article, payload | {"offset_utf16": offset})).status_code == 422
    for patch in ({"request_id": "../bad"}, {"text_version": "bad"}, {"content_id": -1}):
        assert (await send(client, article, payload | patch)).status_code == 422
    assert (await send(client, article, payload | {"text_version": "0" * 64})).status_code == 409
    article.audio_url = "https://bookmarks.test/audio.mp3"
    await session.commit()
    assert (await send(client, article, payload)).status_code == 422


async def test_text_replacement_rejects_old_reports_and_cannot_receive_an_old_bookmark(client, session, user, article):
    initial = await current(client, article)
    first = (await send(client, article, body(initial))).json()
    content = ArticleContent(
        episode_id=article.id,
        owner_user_id=user.id,
        title="New text",
        text="Replacement words.",
        html="<p>Replacement words.</p>",
        digest="replacement",
        source="browser",
    )
    session.add(content)
    await session.flush()
    session.add(SavedArticle(user_id=user.id, episode_id=article.id, content_id=content.id, saved_at=utcnow()))
    await session.commit()
    changed = await current(client, article)
    assert changed["content_id"] == content.id and changed["bookmark"] is None
    assert changed["revision"] != first["progress"]["revision"]
    assert (await send(client, article, body(first["progress"], request_id="stale"))).status_code == 409
    retry = (await send(client, article, body(initial))).json()
    assert retry["progress"] == changed and retry["accepted_revision"] == first["accepted_revision"]


async def test_filing_undo_preserves_the_exact_text_bookmark_without_ai(client, article):
    first = await send(client, article, body(await current(client, article)))
    bookmark = first.json()["progress"]["bookmark"]
    filed = await client.post("/actions", json={"action": "restore", "episode_id": article.id, "request_id": "clear"})
    assert filed.status_code == 200 and (await current(client, article))["bookmark"] is None
    undone = await client.post("/actions", json={"action": "undo", "request_id": "undo"})
    assert undone.status_code == 200
    assert (await current(client, article))["bookmark"] == bookmark


async def test_grouped_copy_inherits_exact_text_but_newer_filing_blocks_old_progress(client, session, user, article):
    article.link = "https://bookmarks.test/story"
    feed = Feed(url="https://copy.test/feed", title="Copy", site_artwork_checked_at=utcnow())
    session.add(feed)
    await session.flush()
    copy = Episode(
        feed=feed, guid="copy", title="Copy", link=article.link, article_text=TEXT, article_html="<p>Text</p>"
    )
    session.add_all([copy, Subscription(user_id=user.id, feed_id=feed.id)])
    await session.commit()
    assert (await client.put(f"/feeds/{article.feed_id}/sources/{feed.id}")).status_code == 204
    first = (await send(client, article, body(await current(client, article)))).json()
    assert (await current(client, copy))["bookmark"] == first["progress"]["bookmark"]
    await client.put(f"/episodes/{copy.id}/state", json={"played": True})
    assert (await send(client, article, body(first["progress"], request_id="late"))).status_code == 409


async def test_private_text_and_bookmarks_stay_account_scoped(client, session, user, article, make_client):
    initial = await current(client, article)
    await send(client, article, body(initial))
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as outsider:
        theirs = await current(outsider, article)
        assert theirs["bookmark"] is None and theirs["revision"] != initial["revision"]
        assert (await send(outsider, article, body(initial))).status_code == 409
        article.feed.owner_user_id = user.id
        await session.commit()
        assert (await send(outsider, article, body(theirs))).status_code == 404


async def test_expiry_and_account_deletion_preserve_retry_safety(client, session, user, article):
    from audioreader.auth.service import delete_user

    payload = body(await current(client, article))
    first = (await send(client, article, payload)).json()
    receipt = await session.get(ArticleProgressReceipt, (user.id, "original"))
    receipt.created_at = utcnow() - timedelta(days=8)
    await session.commit()
    assert (
        await send(client, article, body(first["progress"], request_id="fresh", offset_utf16=0))
    ).status_code == 200
    assert await session.get(ArticleProgressReceipt, (user.id, "original")) is None
    assert (await send(client, article, payload)).status_code == 409
    user_id, episode_id = user.id, article.id
    await delete_user(session, user)
    assert await session.get(ArticleProgressReceipt, (user_id, "fresh")) is None
    assert await session.get(PlaybackPosition, (user_id, episode_id)) is None


async def test_bookmark_and_receipt_roll_back_together(client, session, user, article, monkeypatch):
    payload = body(await current(client, article))
    user_id, episode_id = user.id, article.id

    async def fail_commit():
        raise RuntimeError("Commit unavailable")

    with monkeypatch.context() as patch:
        patch.setattr(session, "commit", fail_commit)
        with pytest.raises(RuntimeError, match="Commit unavailable"):
            await send(client, article, payload)
        await session.rollback()
    assert await session.get(ArticleProgressReceipt, (user_id, "original")) is None
    assert await session.get(PlaybackPosition, (user_id, episode_id)) is None


async def test_selected_capture_change_clears_bookmark_and_old_snapshot_cannot_write(client, session, user, article):
    from audioreader import saved

    selected = (await client.post("/saved", json={"episode_id": article.id})).json()
    original_content = selected["content_id"]
    initial = await current(client, article)
    assert initial["content_id"] == original_content
    first = (await send(client, article, body(initial))).json()
    record = await saved.selection(session, user, article.id)
    await saved.store_capture(
        session,
        user,
        article,
        record,
        "Replacement",
        "<p>New text</p>",
        "Entirely new text with other offsets.",
        "browser",
        replace=True,
    )
    await session.commit()
    changed = await current(client, article)
    assert changed["bookmark"] is None and changed["content_id"] != original_content
    position = await session.get(PlaybackPosition, (user.id, article.id))
    assert position.article_text_version is None and position.article_offset_utf16 is None
    old_text = await client.get(f"/episodes/{article.id}/text?content_id={original_content}")
    assert old_text.status_code == 200 and old_text.json()["article_progress"] is None
    assert (await send(client, article, body(first["progress"], request_id="old-snapshot"))).status_code == 409


async def test_new_bookmark_after_filing_prevents_undo_from_restoring_an_old_passage(client, article):
    initial = (await send(client, article, body(await current(client, article)))).json()
    await client.post("/actions", json={"action": "dismiss", "episode_id": article.id, "request_id": "dismiss"})
    progress = await current(client, article)
    updated = await send(client, article, body(progress, request_id="new-listening", offset_utf16=0))
    assert updated.status_code == 200
    undone = (await client.post("/actions", json={"action": "undo", "request_id": "undo"})).json()
    assert undone["action"] == "unknown"
    assert (await current(client, article))["bookmark"]["offset_utf16"] == 0
    assert initial["progress"]["bookmark"]["offset_utf16"] == OFFSET
