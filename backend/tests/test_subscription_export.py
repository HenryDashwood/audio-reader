from xml.etree import ElementTree

import pytest
from sqlalchemy import func, select

from audioreader.imports import opml
from audioreader.models import FEED_SOURCE_EMAIL, Episode, Feed, Subscription, User


async def test_export_round_trips_own_feeds_and_preserves_private_addresses(client, session, user, make_client):
    other = User(display_name="Other")
    session.add(other)
    await session.flush()
    public = Feed(
        url="https://public.example/feed?a=1&b=2", title='Café & 科学 "news"\x01', site_url="https://[broken"
    )
    personal = Feed(
        url="private-rss:own",
        private_fetch_url="https://reader:password@paid.example/feed?token=one&x=two",
        title="Personal",
        owner_user_id=user.id,
    )
    foreign = Feed(
        url="private-rss:other",
        private_fetch_url="https://other.example/secret",
        title="Foreign",
        owner_user_id=other.id,
    )
    unfollowed = Feed(url="https://unfollowed.example/feed", title="Unfollowed")
    session.add_all([public, personal, foreign, unfollowed])
    await session.flush()
    session.add_all(
        [
            Subscription(user_id=user.id, feed_id=public.id, latest_after_episode_id=42),
            Subscription(user_id=user.id, feed_id=personal.id, group_feed_id=public.id),
            Subscription(user_id=other.id, feed_id=foreign.id),
            # Even inconsistent membership must not make a private link exportable.
            Subscription(user_id=user.id, feed_id=foreign.id),
        ]
    )
    session.add(Episode(feed_id=personal.id, guid="private", title="Not in OPML", content_html="Not in OPML"))
    await session.commit()
    response = await client.get("/feeds/export")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/x-opml")
    assert response.headers["cache-control"] == "no-store"
    assert 'filename="Magpie-subscriptions.opml"' in response.headers["content-disposition"]
    parsed = opml.parse(response.content)
    assert [entry.url for entry in parsed.entries] == [public.url, personal.private_fetch_url]
    assert parsed.entries[0].title == 'Café & 科学 "news"'
    assert all(entry.status == "ready" for entry in parsed.entries)
    assert "private-rss:" not in response.text
    assert "Not in OPML" not in response.text and "Foreign" not in response.text
    assert await session.scalar(select(func.count()).select_from(Subscription)) == 4
    assert (
        await session.scalar(
            select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == public.id)
        )
    ).latest_after_episode_id == 42
    async with make_client(other) as stranger:
        exported = (await stranger.get("/feeds/export")).content
        assert [entry.url for entry in opml.parse(exported).entries] == [foreign.private_fetch_url]


@pytest.mark.parametrize("direct_follow", [False, True])
async def test_export_includes_newsletter_rss_companion_once_but_not_email_address(
    client, session, user, direct_follow
):
    rss = Feed(url="https://publication.example/feed", title="Publication")
    session.add(rss)
    await session.flush()
    email = Feed(
        url="email:sender@example.org",
        title="Publication mail",
        source=FEED_SOURCE_EMAIL,
        owner_user_id=user.id,
        companion_feed_id=rss.id,
    )
    email_only = Feed(
        url="email:private@example.org", title="Email only", source=FEED_SOURCE_EMAIL, owner_user_id=user.id
    )
    session.add_all([email, email_only])
    await session.flush()
    session.add_all(
        [
            Subscription(user_id=user.id, feed_id=feed.id)
            for feed in ([rss] if direct_follow else []) + [email, email_only]
        ]
    )
    await session.commit()
    response = await client.get("/feeds/export")
    outlines = ElementTree.fromstring(response.content).findall("body/outline")
    assert len(outlines) == 1 and outlines[0].attrib["xmlUrl"] == rss.url
    assert "sender@example.org" not in response.text and "private@example.org" not in response.text


async def test_empty_export_explains_no_portable_subscriptions(client):
    response = await client.get("/feeds/export")
    assert response.status_code == 409
    assert "no podcast or RSS subscriptions" in response.json()["detail"]["spoken_response"]
