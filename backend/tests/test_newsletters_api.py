"""Newsletters by email: the inbound endpoint and what she sees afterwards."""

from datetime import timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy import select
from tests.newsletter_fixtures import ISSUE_TEXT, build_email

from audioreader.auth import service as auth_service
from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.fetcher import FeedFetchError
from audioreader.feeds.poller import poll_all_feeds, prune_orphaned_feeds
from audioreader.models import (
    APPROVAL_LEFT,
    APPROVAL_PENDING,
    Episode,
    Feed,
    InboundMessage,
    Subscription,
    User,
    utcnow,
)
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
        assert len(local.split("-")) == service.TOKEN_WORDS
        assert first == second

    def test_tokens_are_words_somebody_can_say(self):
        tokens = {service.new_inbound_token() for _ in range(50)}

        assert len(tokens) == 50
        for token in tokens:
            words = token.split("-")
            assert len(words) == service.TOKEN_WORDS
            assert all(word.isalpha() and word.islower() and word in service._WORDS for word in words)

    def test_the_wordlist_is_short_plain_words(self):
        # Enough for the address to be hard to stumble on: 400 words cubed
        # is 64 million, and a guess only ever reaches the pending list.
        assert len(service._WORDS) >= 400
        assert len(set(service._WORDS)) == len(service._WORDS)
        for word in service._WORDS:
            assert word.isalpha() and word.islower() and 3 <= len(word) <= 5, word


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


STOP_LINK = "https://news.test/unsubscribe?token=abc"
#: At a shared mail domain, so following it looks for no feed on the web.
SENDER = "Matt Levine <moneystuff@gmail.com>"


async def followed(client, address: str, raw: bytes | None = None, **email) -> int:
    raw = raw or build_email(to=address, sender=SENDER, **email)
    feed_id = (await deliver(client, raw, to=address)).json()["feed_id"]
    await client.post(f"/newsletters/{feed_id}/approve")
    return feed_id


class TestUnfollow:
    async def test_leaving_keeps_what_it_sent_out_of_sight(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = await followed(client, address)

        assert (await client.delete(f"/feeds/{feed_id}")).status_code == 204

        feed = await session.get(Feed, feed_id)
        assert feed is not None and feed.approval == APPROVAL_LEFT
        assert len((await session.scalars(select(Episode))).all()) == 1
        assert (await client.get("/feeds")).json() == []
        assert (await client.get("/episodes")).json() == []
        assert await pending_ids(client) == []
        assert (await client.get(f"/feeds/{feed_id}/episodes")).status_code == 404

    async def test_a_one_click_sender_is_told_with_a_post(self, client, inbound_enabled, respx_mock):
        stop = respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        raw = build_email(
            to=address, sender=SENDER, unsubscribe=f"<mailto:stop@news.test>, <{STOP_LINK}>", one_click=True
        )
        feed_id = await followed(client, address, raw=raw)

        await client.delete(f"/feeds/{feed_id}")

        assert stop.call_count == 1
        assert stop.calls[0].request.content == b"List-Unsubscribe=One-Click"

    async def test_a_plain_link_is_opened_as_she_would(self, client, inbound_enabled, respx_mock):
        stop = respx_mock.get(STOP_LINK).respond(200, content=b"<p>You have been unsubscribed.</p>")
        address = await address_of(client)
        feed_id = await followed(client, address, unsubscribe=f"<{STOP_LINK}>")

        await client.delete(f"/feeds/{feed_id}")

        assert stop.call_count == 1

    async def test_a_sender_that_cannot_be_reached_is_still_left(self, client, inbound_enabled, respx_mock):
        respx_mock.post(STOP_LINK).respond(500)
        address = await address_of(client)
        feed_id = await followed(client, address, unsubscribe=f"<{STOP_LINK}>", one_click=True)

        assert (await client.delete(f"/feeds/{feed_id}")).status_code == 204
        assert (await client.get("/feeds")).json() == []

    async def test_the_newest_issues_way_of_stopping_is_the_one_used(self, client, inbound_enabled, respx_mock):
        old = respx_mock.post("https://news.test/unsubscribe?token=old").respond(200)
        new = respx_mock.post("https://news.test/unsubscribe?token=new").respond(200)
        address = await address_of(client)
        feed_id = await followed(
            client, address, unsubscribe="<https://news.test/unsubscribe?token=old>", one_click=True
        )
        await deliver(
            client,
            build_email(
                to=address,
                sender=SENDER,
                message_id="<2@x>",
                unsubscribe="<https://news.test/unsubscribe?token=new>",
                one_click=True,
            ),
            to=address,
        )

        await client.delete(f"/feeds/{feed_id}")

        assert (old.call_count, new.call_count) == (0, 1)

    async def test_a_sender_that_keeps_writing_asks_again_with_its_history(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = await followed(client, address)
        await client.delete(f"/feeds/{feed_id}")

        response = await deliver(client, build_email(to=address, sender=SENDER, message_id="<again@x>"), to=address)

        receipt = response.json()
        assert (receipt["status"], receipt["feed_id"]) == ("pending", feed_id)
        waiting = (await client.get("/newsletters/pending")).json()
        assert [(item["id"], item["message_count"]) for item in waiting] == [(feed_id, 2)]

    async def test_coming_back_finds_everything_still_there(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = await followed(client, address)
        await client.delete(f"/feeds/{feed_id}")
        issue_two = build_email(to=address, sender=SENDER, message_id="<again@x>", subject="Issue two")
        await deliver(client, issue_two, to=address)

        await client.post(f"/newsletters/{feed_id}/approve")

        latest = (await client.get("/episodes")).json()
        assert sorted(row["title"] for row in latest) == ["Issue two", "Money Stuff: Things Happen"]

    async def test_leaving_notes_that_the_sender_accepted(self, client, inbound_enabled, respx_mock, session):
        respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        feed_id = await followed(client, address, unsubscribe=f"<{STOP_LINK}>", one_click=True)

        await client.delete(f"/feeds/{feed_id}")

        feed = await session.get(Feed, feed_id)
        assert feed is not None and feed.stop_told_at is not None and feed.stop_tried_at is not None

    async def test_the_address_is_recovered_from_mail_kept_before_it_was_noted(
        self, client, inbound_enabled, respx_mock, session
    ):
        stop = respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        feed_id = await followed(client, address, unsubscribe=f"<{STOP_LINK}>", one_click=True)
        # As if the issue had arrived before the feed noted addresses.
        feed = await session.get(Feed, feed_id)
        assert feed is not None
        feed.unsubscribe_url = feed.unsubscribe_post = None
        await session.commit()

        await client.delete(f"/feeds/{feed_id}")

        assert stop.call_count == 1
        assert feed.unsubscribe_url == STOP_LINK

    async def test_blocking_tells_the_sender_too(self, client, inbound_enabled, respx_mock):
        stop = respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        raw = build_email(to=address, sender=SENDER, unsubscribe=f"<{STOP_LINK}>", one_click=True)
        feed_id = (await deliver(client, raw, to=address)).json()["feed_id"]

        await client.post(f"/newsletters/{feed_id}/block")

        assert stop.call_count == 1

    async def test_a_sender_that_did_not_accept_is_asked_again_daily(
        self, client, inbound_enabled, respx_mock, session
    ):
        stop = respx_mock.post(STOP_LINK).mock(side_effect=[httpx.Response(503), httpx.Response(200)])
        address = await address_of(client)
        feed_id = await followed(client, address, unsubscribe=f"<{STOP_LINK}>", one_click=True)
        await client.delete(f"/feeds/{feed_id}")
        assert stop.call_count == 1

        # Too soon: nothing is asked twice within a day.
        assert await service.tell_left_senders(session, now=utcnow() + timedelta(hours=1)) == 0
        assert stop.call_count == 1
        # A day on, it is asked again and this time accepts.
        assert await service.tell_left_senders(session, now=utcnow() + timedelta(days=1, minutes=1)) == 1
        assert stop.call_count == 2
        assert await service.tell_left_senders(session, now=utcnow() + timedelta(days=3)) == 0

    async def test_a_sender_with_no_address_is_tried_once_and_left_alone(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = await followed(client, address)
        await client.delete(f"/feeds/{feed_id}")
        feed = await session.get(Feed, feed_id)
        assert feed is not None and feed.stop_tried_at is not None and feed.stop_told_at is None

        assert await service.tell_left_senders(session, now=utcnow() + timedelta(days=5)) == 0

    async def test_a_left_newsletter_is_forgotten_after_the_retention_window(self, client, inbound_enabled, session):
        address = await address_of(client)
        feed_id = await followed(client, address)
        await client.delete(f"/feeds/{feed_id}")
        days = settings.newsletter_pending_retention_days

        kept = await service.prune_newsletters(session, now=utcnow() + timedelta(days=days - 1))
        assert kept.pending_feeds == 0 and await session.get(Feed, feed_id) is not None

        gone = await service.prune_newsletters(session, now=utcnow() + timedelta(days=days + 1))
        assert gone.pending_feeds == 1 and await session.get(Feed, feed_id) is None


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


def forwarded_issue(**overrides) -> bytes:
    """An issue addressed to her main inbox, as a rule there would pass on."""
    fields: dict[str, Any] = {"sender": SENDER, "to": "henry@gmail.com", "unsubscribe": f"<{STOP_LINK}>"}
    fields.update(one_click=True, **overrides)
    return build_email(**fields)


GOOGLE_LINK = "https://mail-settings.google.com/mail/vf-abc123-def"
GOOGLE_PAGE = "https://mail.google.com/mail/vf-abc123-def"
GOOGLE_FORM = (
    b"<html><body><h1>Confirmation</h1><p>Please confirm mail forwarding of henry@gmail.com to "
    b'hefty-prism-bolt@magpieinbox.com.</p><form action="" method="post"><p><input type="submit" value="Confirm">'
    b"</p></form></body></html>"
)


class TestForwardedMail:
    async def test_a_forwarded_newsletter_is_never_told_to_stop(self, client, inbound_enabled, respx_mock, session):
        stop = respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        feed_id = await followed(client, address, raw=forwarded_issue())
        assert (await client.get("/feeds")).json()[0]["forwarded"] is True

        await client.delete(f"/feeds/{feed_id}")
        await service.tell_left_senders(session, now=utcnow() + timedelta(days=3))

        assert stop.call_count == 0
        feed = await session.get(Feed, feed_id)
        assert feed is not None and feed.approval == APPROVAL_LEFT and feed.stop_told_at is None

    async def test_blocking_a_forwarded_sender_does_not_tell_it_either(self, client, inbound_enabled, respx_mock):
        stop = respx_mock.post(STOP_LINK).respond(200)
        address = await address_of(client)
        feed_id = (await deliver(client, forwarded_issue(), to=address)).json()["feed_id"]

        await client.post(f"/newsletters/{feed_id}/block")

        assert stop.call_count == 0

    async def test_the_newest_issue_decides(self, client, inbound_enabled):
        address = await address_of(client)
        feed_id = await followed(client, address, raw=forwarded_issue())
        # The subscription moved to her address: mail comes straight now.
        await deliver(client, build_email(sender=SENDER, to=address, message_id="<direct@x>"), to=address)

        shows = (await client.get("/feeds")).json()

        assert [(show["id"], show["forwarded"]) for show in shows] == [(feed_id, False)]

    async def test_a_message_she_forwarded_by_hand_files_under_the_writer(self, client, inbound_enabled):
        address = await address_of(client)
        text = (
            "---------- Forwarded message ---------\nFrom: Matt Levine <noreply@mail.bloombergbusiness.com>\n"
            "Subject: Money Stuff: Things Happen\n\nThings happened today.\n"
        )
        raw = build_email(
            sender="Henry <henry@gmail.com>",
            to=address,
            subject="Fwd: Money Stuff: Things Happen",
            html=None,
            text=text,
        )

        await deliver(client, raw, to=address)

        waiting = (await client.get("/newsletters/pending")).json()
        assert [(item["title"], item["latest_title"]) for item in waiting] == [
            ("Matt Levine", "Money Stuff: Things Happen")
        ]

    async def test_gmails_forwarding_question_is_answered_yes(self, client, inbound_enabled, respx_mock, session):
        # The link redirects to a page whose Confirm button is an empty POST.
        respx_mock.get(GOOGLE_LINK).respond(302, headers={"Location": GOOGLE_PAGE})
        respx_mock.get(GOOGLE_PAGE).respond(200, content=GOOGLE_FORM, content_type="text/html")
        confirm = respx_mock.post(GOOGLE_PAGE).respond(200, content=b"Confirmation successful")
        address = await address_of(client)
        raw = build_email(
            sender="Gmail Team <forwarding-noreply@google.com>",
            to=address,
            subject="(#123456789) Gmail Forwarding Confirmation - Receive Mail from henry@gmail.com",
            text="henry@gmail.com has requested to automatically forward mail to your email address.\n"
            f"Confirmation code: 123456789\n\n{GOOGLE_LINK}\n",
            html=None,
        )

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "confirmed"
        assert confirm.call_count == 1 and confirm.calls[0].request.method == "POST"
        pressed = confirm.calls[0].request
        assert pressed.headers["content-type"] == "application/x-www-form-urlencoded"
        assert pressed.headers["referer"] == GOOGLE_PAGE
        assert await pending_ids(client) == []
        record = (await session.scalars(select(InboundMessage))).one()
        assert record.error == "forwarding confirmation followed; not an issue"

    async def test_a_forwarding_question_that_cannot_be_answered_waits_for_her(
        self, client, inbound_enabled, respx_mock
    ):
        respx_mock.get(GOOGLE_LINK).respond(200, content=GOOGLE_FORM, content_type="text/html")
        respx_mock.post(GOOGLE_LINK).respond(500)
        address = await address_of(client)
        raw = build_email(
            sender="Gmail Team <forwarding-noreply@google.com>",
            to=address,
            subject="(#123456789) Gmail Forwarding Confirmation - Receive Mail from henry@gmail.com",
            text=f"{GOOGLE_LINK}\n",
            html=None,
        )

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "pending"
        waiting = (await client.get("/newsletters/pending")).json()
        assert "123456789" in waiting[0]["latest_title"]

    async def test_the_link_is_found_at_either_google_host(self, client, inbound_enabled, respx_mock):
        page = "https://mail.google.com/mail/u/0/vf-xyz789"
        respx_mock.get(page).respond(200, content=GOOGLE_FORM, content_type="text/html")
        confirm = respx_mock.post(page).respond(200)
        address = await address_of(client)
        raw = build_email(
            sender="Gmail Team <forwarding-noreply@google.com>",
            to=address,
            subject="(Gmail Forwarding confirmation – Receive mail from henry@gmail.com",
            html=f'<p>To allow this, click <a href="{page}">this link</a>.</p>',
        )

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "confirmed" and confirm.call_count == 1

    async def test_the_button_shown_again_means_no(self, client, inbound_enabled, respx_mock):
        respx_mock.get(GOOGLE_LINK).respond(200, content=GOOGLE_FORM, content_type="text/html")
        respx_mock.post(GOOGLE_LINK).respond(200, content=GOOGLE_FORM, content_type="text/html")
        address = await address_of(client)
        raw = build_email(
            sender="Gmail Team <forwarding-noreply@google.com>",
            to=address,
            subject="(#123456789) Gmail Forwarding Confirmation - Receive Mail from henry@gmail.com",
            text=f"{GOOGLE_LINK}\n",
            html=None,
        )

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "pending"

    async def test_a_page_without_the_button_is_not_pressed(self, client, inbound_enabled, respx_mock):
        respx_mock.get(GOOGLE_LINK).respond(200, content=b"<p>This link has expired.</p>", content_type="text/html")
        pressed = respx_mock.post(GOOGLE_LINK).respond(200)
        address = await address_of(client)
        raw = build_email(
            sender="Gmail Team <forwarding-noreply@google.com>",
            to=address,
            subject="(#123456789) Gmail Forwarding Confirmation - Receive Mail from henry@gmail.com",
            text=f"{GOOGLE_LINK}\n",
            html=None,
        )

        response = await deliver(client, raw, to=address)

        assert response.json()["status"] == "pending" and pressed.call_count == 0
