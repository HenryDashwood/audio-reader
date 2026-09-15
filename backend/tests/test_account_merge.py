"""Account linking preserves private libraries after either provider was used first."""

import uuid
from datetime import timedelta

import pytest
from sqlalchemy import func, select, text

import test_auth_api as auth_fixtures
from audioreader.auth import service
from audioreader.auth.apple import AppleIdentity
from audioreader.config import settings
from audioreader.models import (
    ArticleContent,
    AuthSession,
    Episode,
    Feed,
    InboundMessage,
    NewsletterInboxAlias,
    NewsletterSignup,
    PlaybackPosition,
    SavedArticle,
    Subscription,
    User,
    UserIdentity,
    VoiceCommandReceipt,
    VoiceUndo,
    utcnow,
)
from audioreader.newsletters import service as newsletters

apple_keys = auth_fixtures.apple_keys
auth_client = auth_fixtures.auth_client
google_token = auth_fixtures.google_token
make_identity_token = auth_fixtures.make_identity_token


@pytest.mark.parametrize("provider", ["apple", "google"])
async def test_link_combines_libraries_preserves_target_session_and_both_logins(
    auth_client, session, make_identity_token, google_token, provider, monkeypatch
):
    await session.execute(text("PRAGMA foreign_keys=ON"))
    apple = (await auth_client.post("/auth/apple", json={"identity_token": make_identity_token()})).json()
    google = (await auth_client.post("/auth/google", json={"identity_token": google_token()})).json()
    target_login, source_login = (google, apple) if provider == "apple" else (apple, google)
    target = await session.get(User, uuid.UUID(target_login["user"]["id"]))
    source = await session.get(User, uuid.UUID(source_login["user"]["id"]))
    target_id, source_id = target.id, source.id
    target.inbound_token, source.inbound_token = "current-inbox", "original-inbox"
    target.ai_consent_version = 3
    target.ai_data_sharing_consented_at = utcnow()
    shared = Feed(url="https://test.example/shared", title="Shared")
    original = Feed(url="https://test.example/original", title="Original")
    private = Feed(
        url=f"email://{source_id}/sender@example.org",
        title="Private",
        source="email",
        owner_user_id=source_id,
        approval="approved",
    )
    session.add_all([shared, original, private])
    await session.flush()
    session.add_all(
        [
            Subscription(user_id=target_id, feed_id=shared.id, latest_after_episode_id=10),
            Subscription(user_id=source_id, feed_id=shared.id, latest_after_episode_id=20),
            Subscription(user_id=source_id, feed_id=original.id, group_feed_id=shared.id),
            Subscription(user_id=source_id, feed_id=private.id),
        ]
    )
    episode = Episode(feed_id=shared.id, guid="shared", title="Shared episode")
    saved_episode = Episode(guid="private", title="Private capture")
    session.add_all([episode, saved_episode])
    await session.flush()
    capture = ArticleContent(
        episode_id=saved_episode.id,
        owner_user_id=source_id,
        title="Private title",
        text="Private text",
        html="<p>Private text</p>",
        digest="abc",
        source="browser",
    )
    session.add(capture)
    await session.flush()
    later = utcnow()
    earlier = later - timedelta(days=1)
    session.add_all(
        [
            SavedArticle(user_id=source_id, episode_id=saved_episode.id, content_id=capture.id, saved_at=earlier),
            PlaybackPosition(
                user_id=source_id,
                episode_id=saved_episode.id,
                content_id=capture.id,
                position_seconds=42,
                updated_at=later,
            ),
            PlaybackPosition(user_id=target_id, episode_id=episode.id, position_seconds=90, updated_at=earlier),
            PlaybackPosition(
                user_id=source_id, episode_id=episode.id, position_seconds=15, dismissed=True, updated_at=later
            ),
            InboundMessage(user_id=source_id, feed_id=private.id, message_id="one", raw=b"private", raw_size=7),
            NewsletterSignup(
                user_id=source_id,
                site_url="https://example.org",
                publication="Private",
                platform="substack",
                expected_senders="sender@example.org",
            ),
            VoiceCommandReceipt(user_id=target_id, request_id="keep", fingerprint="one"),
            VoiceCommandReceipt(user_id=source_id, request_id="retire", fingerprint="two"),
            VoiceUndo(user_id=target_id, payload="{}"),
            VoiceUndo(user_id=source_id, payload="{}"),
        ]
    )
    await session.commit()
    headers = {"Authorization": f"Bearer {target_login['token']}"}
    proof = make_identity_token() if provider == "apple" else google_token()
    for _ in range(2):  # a lost response can be retried without copying anything twice
        response = await auth_client.post(
            f"/me/identities/{provider}", headers=headers, json={"identity_token": proof}
        )
        assert response.status_code == 200, response.text
        assert response.json() == {"providers": ["apple", "google"]}
    assert await session.scalar(select(func.count(User.id))) == 1
    assert (await auth_client.get("/me", headers=headers)).json()["ai_data_sharing_consented"] is False
    assert (
        await auth_client.get("/me", headers={"Authorization": f"Bearer {source_login['token']}"})
    ).status_code == 401
    for endpoint, proof in (("apple", make_identity_token()), ("google", google_token())):
        response = await auth_client.post(f"/auth/{endpoint}", json={"identity_token": proof})
        assert response.json()["user"]["id"] == str(target_id)
    subscriptions = list(await session.scalars(select(Subscription).where(Subscription.user_id == target_id)))
    assert {s.feed_id for s in subscriptions} == {shared.id, original.id, private.id}
    assert next(s for s in subscriptions if s.feed_id == shared.id).latest_after_episode_id == 20
    assert next(s for s in subscriptions if s.feed_id == original.id).group_feed_id == shared.id
    position = await session.get(PlaybackPosition, (target_id, episode.id))
    assert (position.position_seconds, position.dismissed) == (15, True)
    saved = await session.get(SavedArticle, (target_id, saved_episode.id))
    assert saved.content_id == capture.id
    assert (await session.get(ArticleContent, capture.id)).owner_user_id == target_id
    assert (await session.get(PlaybackPosition, (target_id, saved_episode.id))).position_seconds == 42
    assert await session.scalar(select(Feed.owner_user_id).where(Feed.id == private.id)) == target_id
    assert await session.scalar(select(InboundMessage.user_id)) == target_id
    assert await session.scalar(select(NewsletterSignup.user_id)) == target_id
    assert list(await session.scalars(select(VoiceCommandReceipt.request_id))) == ["keep"]
    assert await session.scalar(select(func.count()).select_from(VoiceUndo)) == 0
    monkeypatch.setattr(settings, "inbound_email_domain", "in.magpie.test")
    for token in ("current-inbox", "original-inbox"):
        recipient = await newsletters.user_for_recipient(session, f"{token}+tag@in.magpie.test")
        assert recipient is not None and recipient.id == target_id
    assert (await session.get(NewsletterInboxAlias, "original-inbox")).namespace_user_id == source_id
    # Deleting the combined account cleans up imported private data and aliases.
    await service.delete_user(session, target)
    assert await newsletters.user_for_recipient(session, "original-inbox@in.magpie.test") is None
    assert await session.get(ArticleContent, capture.id) is None
    assert await session.get(Feed, private.id) is None


async def test_duplicate_saved_versions_never_mix_listening_seconds(session):
    target, target_token = await service.login(session, AppleIdentity(subject="google", email=None), provider="google")
    source, _ = await service.login(session, AppleIdentity(subject="apple", email=None))
    episode = Episode(guid="one", title="Article")
    session.add(episode)
    await session.flush()
    copies = [
        ArticleContent(
            episode_id=episode.id,
            owner_user_id=user.id,
            title="Article",
            text=body,
            html=f"<p>{body}</p>",
            digest=body,
            source="browser",
        )
        for user, body in ((target, "short"), (source, "longer"))
    ]
    session.add_all(copies)
    await session.flush()
    now = utcnow()
    for user, copy, date, seconds in ((target, copies[0], now - timedelta(days=1), 12), (source, copies[1], now, 120)):
        session.add(SavedArticle(user_id=user.id, episode_id=episode.id, content_id=copy.id, saved_at=date))
        session.add(
            PlaybackPosition(
                user_id=user.id, episode_id=episode.id, content_id=copy.id, position_seconds=seconds, updated_at=date
            )
        )
    await session.commit()
    await service.link_identity(
        session, target, AppleIdentity(subject="apple", email=None), "apple", session_token=target_token
    )
    assert (await session.get(SavedArticle, (target.id, episode.id))).content_id == copies[0].id
    assert (await session.get(PlaybackPosition, (target.id, episode.id))).position_seconds == 12
    assert list(await session.scalars(select(ArticleContent.owner_user_id))) == [target.id, target.id]


async def test_revoked_session_cannot_combine_accounts_even_with_valid_provider_proof(session):
    target, token = await service.login(session, AppleIdentity(subject="google", email=None), provider="google")
    await service.login(session, AppleIdentity(subject="apple", email=None))
    await service.revoke(session, token)
    with pytest.raises(service.LinkSessionExpired):
        await service.link_identity(
            session, target, AppleIdentity(subject="apple", email=None), "apple", session_token=token
        )
    assert await session.scalar(select(func.count(User.id))) == 2
    assert await session.scalar(select(func.count(UserIdentity.id))) == 2
    assert (await session.get(AuthSession, service.hash_token(token))).revoked_at is not None


async def test_merge_failure_rolls_back_every_move(session, monkeypatch):
    from audioreader.auth import merge

    target, token = await service.login(session, AppleIdentity(subject="google", email=None), provider="google")
    source, source_token = await service.login(session, AppleIdentity(subject="apple", email=None))
    target_id, source_id = target.id, source.id
    feed = Feed(url="https://test.example/feed", title="Private library")
    session.add(feed)
    await session.flush()
    session.add(Subscription(user_id=source_id, feed_id=feed.id))
    await session.commit()

    async def fail_after_subscriptions(*_):
        raise RuntimeError("interrupted")

    monkeypatch.setattr(merge, "_saved_and_positions", fail_after_subscriptions)
    with pytest.raises(RuntimeError, match="interrupted"):
        await service.link_identity(
            session, target, AppleIdentity(subject="apple", email=None), "apple", session_token=token
        )
    await session.rollback()
    assert await session.scalar(select(Subscription.user_id)) == source_id
    original = await service.user_for_token(session, source_token)
    current = await service.user_for_token(session, token)
    assert original is not None and original.id == source_id
    assert current is not None and current.id == target_id


async def test_old_newsletter_address_keeps_delivering_to_original_feed_after_repeated_merges(session, monkeypatch):
    from tests.newsletter_fixtures import ISSUE_TEXT, build_email

    monkeypatch.setattr(settings, "inbound_email_domain", "in.test")
    monkeypatch.setattr(settings, "inbound_email_secret", "test-secret")
    original, _ = await service.login(session, AppleIdentity(subject="original", email=None))
    original.inbound_token = "old-address"
    original_id = original.id
    await session.commit()
    raw = build_email(to="old-address@in.test", html=None, text=ISSUE_TEXT)
    first = await newsletters.receive(session, original, raw)
    feed = await session.get(Feed, first.feed_id)
    feed.approval = "approved"
    await session.commit()
    for name in ("second", "third"):
        current, token = await service.login(session, AppleIdentity(subject=name, email=None), provider="google")
        await service.link_identity(
            session, current, AppleIdentity(subject="original", email=None), "apple", session_token=token
        )
        assert current.inbound_token == "old-address"
        recipient = await newsletters.user_for_recipient(session, "old-address@in.test")
        assert recipient is not None and recipient.id == current.id
        raw = build_email(
            to="not-the-envelope@elsewhere.test", html=None, text=ISSUE_TEXT, message_id=f"<{name}@example.org>"
        )
        delivered = await newsletters.receive(session, recipient, raw, recipient="old-address@in.test")
        assert delivered.feed_id == first.feed_id
        assert (await session.get(Feed, first.feed_id)).approval == "approved"
        assert (await session.get(NewsletterInboxAlias, "old-address")).namespace_user_id == original_id
    assert await session.scalar(select(func.count(Feed.id))) == 1
    assert await session.scalar(select(func.count(Episode.id))) == 3
