"""Newsletters by email: the inbound endpoint and what she sees afterwards."""

from datetime import timedelta

import pytest
from sqlalchemy import select
from tests.newsletter_fixtures import ISSUE_TEXT, build_email

from audioreader.auth import service as auth_service
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.poller import poll_all_feeds, prune_orphaned_feeds
from audioreader.models import APPROVAL_PENDING, Episode, Feed, InboundMessage, Subscription, User, utcnow
from audioreader.newsletters import service

DOMAIN = "in.test"
SECRET = "worker-secret"


@pytest.fixture
def inbound_enabled(monkeypatch):
    monkeypatch.setattr(settings, "inbound_email_domain", DOMAIN)
    monkeypatch.setattr(settings, "inbound_email_secret", SECRET)


async def address_of(client) -> str:
    response = await client.get("/newsletters/address")
    assert response.status_code == 200, response.text
    return response.json()["address"]


async def deliver(client, raw: bytes, *, to: str | None = None, signature: str | None = None):
    headers = {
        "Content-Type": "message/rfc822",
        "X-Magpie-Signature": service.signature_for(raw) if signature is None else signature,
    }
    if to is not None:
        headers["X-Magpie-Recipient"] = to
    return await client.post("/inbound/email", content=raw, headers=headers)


async def pending_ids(client) -> list[int]:
    return [item["id"] for item in (await client.get("/newsletters/pending")).json()]


class TestAddress:
    async def test_not_available_until_configured(self, client):
        response = await client.get("/newsletters/address")

        assert response.status_code == 503
        assert "not available" in response.json()["detail"]["spoken_response"]

    async def test_minted_once_and_stable(self, client, inbound_enabled):
        first = await address_of(client)
        second = await address_of(client)

        local, _, domain = first.partition("@")
        assert domain == DOMAIN
        assert len(local) == service.TOKEN_LENGTH
        assert first == second

    def test_tokens_avoid_characters_that_are_misheard(self):
        for _ in range(200):
            assert not set(service.new_inbound_token()) & set("ilo01")


class TestInboundEndpoint:
    async def test_refused_when_not_configured(self, client):
        response = await client.post("/inbound/email", content=build_email())

        assert response.status_code == 503

    async def test_requires_a_valid_signature(self, client, inbound_enabled):
        address = await address_of(client)
        raw = build_email(to=address)

        assert (await deliver(client, raw, to=address, signature="sha256=deadbeef")).status_code == 401
        assert (await deliver(client, raw, to=address, signature="")).status_code == 401

    async def test_unknown_address_is_undeliverable(self, client, inbound_enabled):
        await address_of(client)

        response = await deliver(client, build_email(), to=f"nobody@{DOMAIN}")

        assert response.status_code == 404

    async def test_other_domains_are_not_ours(self, client, inbound_enabled):
        address = await address_of(client)
        local = address.partition("@")[0]

        assert (await deliver(client, build_email(), to=f"{local}@elsewhere.test")).status_code == 404

    async def test_too_large(self, client, inbound_enabled, monkeypatch):
        monkeypatch.setattr(settings, "inbound_email_max_bytes", 100)
        address = await address_of(client)

        response = await deliver(client, build_email(to=address), to=address)

        assert response.status_code == 413

    async def test_recipient_falls_back_to_the_headers(self, client, inbound_enabled):
        address = await address_of(client)

        response = await deliver(client, build_email(to=address))

        assert response.status_code == 202
        assert response.json()["status"] == "pending"

    async def test_subaddressing_is_tolerated(self, client, inbound_enabled):
        local, _, domain = (await address_of(client)).partition("@")

        response = await deliver(client, build_email(), to=f"{local}+moneystuff@{domain}")

        assert response.status_code == 202

    async def test_unparseable_mail_is_kept_for_later(self, client, inbound_enabled, session):
        address = await address_of(client)
        raw = build_email(html=None, text="   ")

        response = await deliver(client, raw, to=address)

        assert response.status_code == 202
        assert response.json()["status"] == "failed"
        stored = (await session.scalars(select(InboundMessage))).one()
        assert stored.raw == raw
        assert stored.error is not None and "no readable body" in stored.error
        assert stored.episode_id is None


class TestFirstContact:
    async def test_a_new_sender_waits_for_her_answer(self, client, inbound_enabled):
        address = await address_of(client)

        response = await deliver(client, build_email(to=address), to=address)

        assert response.status_code == 202
        body = response.json()
        assert body["status"] == "pending"
        pending = (await client.get("/newsletters/pending")).json()
        assert [item["id"] for item in pending] == [body["feed_id"]]
        assert pending[0]["title"] == "Matt Levine"
        assert pending[0]["sender_address"] == "noreply@mail.bloombergbusiness.com"
        assert pending[0]["message_count"] == 1
        assert pending[0]["latest_title"] == "Money Stuff: Things Happen"

    async def test_nothing_reaches_her_until_she_says_yes(self, client, inbound_enabled):
        address = await address_of(client)
        await deliver(client, build_email(to=address), to=address)

        assert (await client.get("/feeds")).json() == []
        assert (await client.get("/episodes")).json() == []
        assert (await client.get("/search/episodes", params={"q": "things happen"})).json() == []

    async def test_a_second_issue_joins_the_same_pending_sender(self, client, inbound_enabled):
        address = await address_of(client)
        await deliver(client, build_email(to=address), to=address)
        await deliver(
            client, build_email(to=address, message_id="<issue-2@x>", subject="Money Stuff: More"), to=address
        )

        pending = (await client.get("/newsletters/pending")).json()
        assert len(pending) == 1
        assert pending[0]["message_count"] == 2

    async def test_newsletters_from_one_publisher_are_kept_apart(self, client, inbound_enabled):
        address = await address_of(client)
        await deliver(client, build_email(to=address, list_id="Money Stuff <moneystuff.bloomberg.test>"), to=address)
        await deliver(
            client,
            build_email(to=address, message_id="<m@x>", list_id="Matt Levine's Other One <other.bloomberg.test>"),
            to=address,
        )

        titles = sorted(item["title"] for item in (await client.get("/newsletters/pending")).json())
        assert titles == ["Matt Levine's Other One", "Money Stuff"]


class TestApprove:
    async def test_following_makes_it_an_ordinary_article_feed(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]

        response = await client.post(f"/newsletters/{feed_id}/approve")

        assert response.status_code == 200, response.text
        feed = response.json()
        assert feed["source"] == "email"
        assert feed["is_article_feed"] is True
        assert feed["title"] == "Matt Levine"
        assert [item["id"] for item in (await client.get("/feeds")).json()] == [feed_id]
        assert await pending_ids(client) == []

    async def test_the_issues_she_was_asked_about_land_in_latest(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        latest = (await client.get("/episodes")).json()

        assert [item["title"] for item in latest] == ["Money Stuff: Things Happen"]
        assert latest[0]["description"] == "Things happen. Preview text nobody should hear."
        assert latest[0]["author"] == "Matt Levine"
        assert latest[0]["has_text"] is True
        assert latest[0]["audio_url"] is None
        assert latest[0]["link"] == "https://newsletters.example.com/view/abc123"
        assert latest[0]["published_at"].startswith("2026-09-01T12:00:00")
        assert latest[0]["word_count"] is not None and latest[0]["word_count"] > 100

    async def test_the_issue_reads_without_its_email_chrome(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")
        episode_id = (await client.get("/episodes")).json()[0]["id"]

        response = await client.get(f"/episodes/{episode_id}/text")

        assert response.status_code == 200
        text = response.json()["text"]
        assert text.startswith("Things Happen\n\nProgramming note")
        assert "Unsubscribe" not in text
        assert "Preview text" not in text
        assert "<" not in response.json()["html"].split(">")[0] or "<h1>" in response.json()["html"]

    async def test_later_issues_arrive_directly(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        response = await deliver(client, build_email(to=address, message_id="<issue-2@x>", subject="Next"), to=address)

        assert response.json()["status"] == "delivered"
        assert [item["title"] for item in (await client.get("/episodes")).json()] == [
            "Next",
            "Money Stuff: Things Happen",
        ]

    async def test_a_redelivered_issue_is_not_a_second_one(self, client, inbound_enabled):
        address = await address_of(client)
        raw = build_email(to=address)
        feed_id = (await deliver(client, raw, to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "duplicate"
        assert len((await client.get("/episodes")).json()) == 1

    async def test_she_can_search_for_it(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        found = (await client.get("/search/episodes", params={"q": "things happen"})).json()

        assert [item["title"] for item in found] == ["Money Stuff: Things Happen"]

    async def test_a_text_only_issue_reads_as_paragraphs(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address, html=None, text=ISSUE_TEXT), to=address)).json()[
            "feed_id"
        ]
        await client.post(f"/newsletters/{feed_id}/approve")
        episode_id = (await client.get("/episodes")).json()[0]["id"]

        text = (await client.get(f"/episodes/{episode_id}/text")).json()["text"]

        assert text.startswith("Things Happen\n\nProgramming note: Money Stuff will be off tomorrow")

    async def test_approving_twice_is_harmless(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]

        assert (await client.post(f"/newsletters/{feed_id}/approve")).status_code == 200
        assert (await client.post(f"/newsletters/{feed_id}/approve")).status_code == 200
        assert len((await client.get("/feeds")).json()) == 1

    async def test_only_her_own(self, client, inbound_enabled, session, make_client):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        other = User(display_name="Someone Else")
        session.add(other)
        await session.commit()

        async with make_client(other) as other_client:
            assert (await other_client.post(f"/newsletters/{feed_id}/approve")).status_code == 404
            assert (await other_client.post(f"/newsletters/{feed_id}/block")).status_code == 404
            assert (await other_client.get("/newsletters/pending")).json() == []

    async def test_nobody_can_subscribe_to_her_feed_by_naming_it(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        feed = await session.get(Feed, feed_id)
        assert feed is not None
        other = User(display_name="Someone Else")
        session.add(other)
        await session.commit()

        with pytest.raises(FeedFetchError):
            await feed_service.subscribe(session, feed.url, other)
        assert (await session.scalars(select(Subscription).where(Subscription.user_id == other.id))).all() == []


class TestBlock:
    async def test_blocking_drops_what_was_sent_and_what_comes_next(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]

        assert (await client.post(f"/newsletters/{feed_id}/block")).status_code == 204

        assert await pending_ids(client) == []
        assert (await session.scalars(select(Episode))).all() == []
        assert (await session.scalars(select(InboundMessage))).all() == []
        response = await deliver(client, build_email(to=address, message_id="<again@x>"), to=address)
        assert response.json()["status"] == "blocked"
        assert (await session.scalars(select(Episode))).all() == []

    async def test_a_followed_newsletter_can_be_blocked_too(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        await client.post(f"/newsletters/{feed_id}/block")

        assert (await client.get("/feeds")).json() == []
        assert (await client.get("/episodes")).json() == []


class TestUnfollow:
    async def test_leaving_forgets_the_feed_and_the_next_issue_asks_again(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        assert (await client.delete(f"/feeds/{feed_id}")).status_code == 204

        assert await session.get(Feed, feed_id) is None
        assert (await session.scalars(select(Episode))).all() == []
        response = await deliver(client, build_email(to=address, message_id="<again@x>"), to=address)
        assert response.json()["status"] == "pending"
        assert await pending_ids(client) == [response.json()["feed_id"]]


class TestAccountDeletion:
    async def test_her_newsletters_go_with_the_account(self, client, inbound_enabled, session, user):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        await auth_service.delete_user(session, user)

        assert (await session.scalars(select(Feed))).all() == []
        assert (await session.scalars(select(Episode))).all() == []
        assert (await session.scalars(select(InboundMessage))).all() == []


class TestBackgroundWork:
    async def test_the_poller_leaves_email_feeds_alone(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        # No respx mock is active, so any fetch attempt would fail loudly.
        summary = await poll_all_feeds(session)

        assert summary.polled == 0 and summary.failed == 0

    async def test_the_orphan_prune_leaves_pending_senders_alone(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]

        pruned = await prune_orphaned_feeds(session, now=utcnow() + timedelta(days=365))

        assert pruned == 0
        assert await session.get(Feed, feed_id) is not None

    async def test_raw_mail_is_dropped_after_the_retention_window(self, client, inbound_enabled, session):
        address = await address_of(client)
        await deliver(client, build_email(to=address), to=address)
        assert len((await session.scalars(select(InboundMessage))).all()) == 1

        kept = await service.prune_newsletters(session, now=utcnow())
        gone = await service.prune_newsletters(
            session, now=utcnow() + timedelta(days=settings.inbound_raw_retention_days + 1)
        )

        assert kept.raw_messages == 0
        assert gone.raw_messages == 1
        assert (await session.scalars(select(InboundMessage))).all() == []
        # The issue itself is untouched.
        assert len((await session.scalars(select(Episode))).all()) == 1

    async def test_an_unanswered_sender_is_forgotten_once_it_goes_quiet(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        feed = await session.get(Feed, feed_id)
        assert feed is not None and feed.approval == APPROVAL_PENDING

        later = utcnow() + timedelta(days=settings.newsletter_pending_retention_days + 1)
        summary = await service.prune_newsletters(session, now=later)

        assert summary.pending_feeds == 1
        assert await session.get(Feed, feed_id) is None
        assert (await session.scalars(select(Episode))).all() == []

    async def test_a_followed_newsletter_is_never_pruned(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = (await deliver(client, build_email(to=address), to=address)).json()["feed_id"]
        await client.post(f"/newsletters/{feed_id}/approve")

        later = utcnow() + timedelta(days=settings.newsletter_pending_retention_days + 1)
        await service.prune_newsletters(session, now=later)
        await prune_orphaned_feeds(session, now=later)

        assert await session.get(Feed, feed_id) is not None
