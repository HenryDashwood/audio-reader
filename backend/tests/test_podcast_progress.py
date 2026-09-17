"""Durable podcast retries must never rewind newer listening or filing."""

from datetime import timedelta

import pytest
from sqlalchemy import select

from audioreader.models import Episode, Feed, PlaybackPosition, PodcastProgressReceipt, Subscription, User, utcnow


@pytest.fixture
async def podcast(session, user):
    feed = Feed(url="https://progress.test/feed", title="Progress", site_artwork_checked_at=utcnow())
    session.add(feed)
    await session.flush()
    episode = Episode(feed=feed, guid="podcast", title="Podcast", audio_url="https://progress.test/audio.mp3")
    session.add_all([episode, Subscription(user_id=user.id, feed_id=feed.id)])
    await session.commit()
    return episode


async def report(client, episode_id, revision, *, request_id="request-one", seconds=25.5, completed=False):
    return await client.put(
        f"/episodes/{episode_id}/progress",
        json={
            "request_id": request_id,
            "expected_revision": revision,
            "position_seconds": seconds,
            "completed": completed,
        },
    )


async def test_retry_after_lost_reply_does_not_overwrite_later_filing(client, session, user, podcast):
    initial = (await client.get(f"/episodes/{podcast.id}")).json()
    revision = initial["progress_revision"]
    assert len(revision) == 64
    accepted = await report(client, podcast.id, revision)
    assert accepted.status_code == 200
    assert accepted.json()["accepted_revision"] == accepted.json()["episode"]["progress_revision"]
    assert accepted.json()["episode"]["position_seconds"] == 25.5
    assert accepted.json()["episode"]["progress_revision"] != revision
    position = await session.get(PlaybackPosition, (user.id, podcast.id))
    stamp = position.updated_at
    retry = await report(client, podcast.id, revision)
    assert retry.json()["episode"]["progress_revision"] == accepted.json()["episode"]["progress_revision"]
    assert position.updated_at == stamp
    await client.put(f"/episodes/{podcast.id}/state", json={"played": True, "dismissed": True})
    retry_after_filing = await report(client, podcast.id, revision)
    assert retry_after_filing.status_code == 200
    assert retry_after_filing.json()["episode"]["completed"] is True
    assert retry_after_filing.json()["episode"]["dismissed"] is True
    assert retry_after_filing.json()["accepted_revision"] == accepted.json()["accepted_revision"]
    assert retry_after_filing.json()["episode"]["progress_revision"] != accepted.json()["accepted_revision"]
    assert len(list(await session.scalars(select(PodcastProgressReceipt)))) == 1
    reused = await report(client, podcast.id, revision, seconds=99)
    assert reused.status_code == 409


async def test_stale_offline_report_cannot_overwrite_another_device_or_legacy_client(client, podcast):
    revision = (await client.get(f"/episodes/{podcast.id}")).json()["progress_revision"]
    await client.put(f"/episodes/{podcast.id}/position", json={"position_seconds": 70, "completed": False})
    assert (await report(client, podcast.id, revision)).status_code == 409
    current = (await client.get(f"/episodes/{podcast.id}")).json()
    assert current["position_seconds"] == 70
    next_report = await report(client, podcast.id, current["progress_revision"], request_id="request-two", seconds=80)
    assert next_report.status_code == 200
    await client.put(f"/episodes/{podcast.id}/state", json={"played": True})
    assert (
        await report(
            client, podcast.id, next_report.json()["episode"]["progress_revision"], request_id="request-three"
        )
    ).status_code == 409
    assert (await client.get(f"/episodes/{podcast.id}")).json()["completed"] is True


async def test_expired_receipts_remain_safe_and_other_accounts_have_independent_requests(
    client, session, user, podcast, make_client
):
    revision = (await client.get(f"/episodes/{podcast.id}")).json()["progress_revision"]
    first = (await report(client, podcast.id, revision)).json()
    receipt = await session.get(PodcastProgressReceipt, (user.id, "request-one"))
    receipt.created_at = utcnow() - timedelta(days=8)
    await session.commit()
    assert (
        await report(client, podcast.id, first["episode"]["progress_revision"], request_id="request-two", seconds=30)
    ).status_code == 200
    assert await session.get(PodcastProgressReceipt, (user.id, "request-one")) is None
    assert (await report(client, podcast.id, revision)).status_code == 409
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as second:
        other_revision = (await second.get(f"/episodes/{podcast.id}")).json()["progress_revision"]
        assert other_revision != revision
        assert (await report(second, podcast.id, other_revision)).status_code == 200
    assert (await client.get(f"/episodes/{podcast.id}")).json()["position_seconds"] == 30


async def test_articles_private_items_and_invalid_updates_are_rejected(client, session, user, podcast, make_client):
    revision = (await client.get(f"/episodes/{podcast.id}")).json()["progress_revision"]
    for patch in ({"expected_revision": "bad"}, {"request_id": "../bad"}, {"position_seconds": -1}):
        payload = {"request_id": "valid", "expected_revision": revision, "position_seconds": 1} | patch
        assert (await client.put(f"/episodes/{podcast.id}/progress", json=payload)).status_code == 422
    article = Episode(feed=podcast.feed, guid="article", title="Text", article_text="Words")
    session.add(article)
    await session.commit()
    assert (await client.get(f"/episodes/{article.id}")).json()["progress_revision"] is None
    assert (await report(client, article.id, revision)).status_code == 422
    feed = await session.get(Feed, podcast.feed_id)
    feed.owner_user_id = user.id
    other = User(display_name="Other")
    session.add(other)
    await session.commit()
    async with make_client(other) as second:
        assert (await report(second, podcast.id, revision)).status_code == 404
    assert (await report(client, 999999, revision)).status_code == 404


async def test_grouped_copy_filing_invalidates_an_offline_progress_token(client, session, user, podcast):
    podcast.link = "https://progress.test/story"
    other = Feed(url="https://other.test/feed", title="Other", site_artwork_checked_at=utcnow())
    session.add(other)
    await session.flush()
    sibling = Episode(
        feed=other, guid="copy", title="Copy", link=podcast.link, audio_url="https://other.test/audio.mp3"
    )
    session.add_all([sibling, Subscription(user_id=user.id, feed_id=other.id)])
    await session.commit()
    assert (await client.put(f"/feeds/{podcast.feed_id}/sources/{other.id}")).status_code == 204
    revision = (await client.get(f"/episodes/{podcast.id}")).json()["progress_revision"]
    assert (await client.put(f"/episodes/{sibling.id}/state", json={"played": True})).status_code == 204
    assert (await report(client, podcast.id, revision)).status_code == 409
    assert (await client.get(f"/episodes/{podcast.id}")).json()["completed"] is True


async def test_position_and_receipt_roll_back_together_when_commit_fails(client, session, user, podcast, monkeypatch):
    episode_id, user_id = podcast.id, user.id
    revision = (await client.get(f"/episodes/{episode_id}")).json()["progress_revision"]

    async def fail_commit():
        raise RuntimeError("Commit unavailable")

    with monkeypatch.context() as patch:
        patch.setattr(session, "commit", fail_commit)
        with pytest.raises(RuntimeError, match="Commit unavailable"):
            await report(client, episode_id, revision)
        await session.rollback()
    assert await session.get(PlaybackPosition, (user_id, episode_id)) is None
    assert await session.get(PodcastProgressReceipt, (user_id, "request-one")) is None


async def test_account_deletion_removes_progress_receipts_but_keeps_shared_catalog(client, session, user, podcast):
    from audioreader.auth.service import delete_user

    episode_id, user_id = podcast.id, user.id
    revision = (await client.get(f"/episodes/{episode_id}")).json()["progress_revision"]
    assert (await report(client, episode_id, revision)).status_code == 200
    await delete_user(session, user)
    assert await session.get(PodcastProgressReceipt, (user_id, "request-one")) is None
    assert await session.get(PlaybackPosition, (user_id, episode_id)) is None
    assert await session.get(Episode, episode_id) is not None
