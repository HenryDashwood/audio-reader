"""A newsletter's feed on the web, linked to the one that arrives by email."""

from datetime import timedelta

import pytest
from sqlalchemy import select

from audioreader.config import settings
from audioreader.feeds import service as feed_service
from audioreader.feeds.poller import poll_all_feeds, prune_orphaned_feeds
from audioreader.models import (
    APPROVAL_APPROVED,
    FEED_SOURCE_EMAIL,
    Episode,
    Feed,
    NewsletterSignup,
    Subscription,
    utcnow,
)
from audioreader.newsletters import companions

SITE = "https://bensouthwood.substack.com"
FEED_URL = f"{SITE}/feed"

HOMEPAGE = f"""<html><head><title>Baldwin</title>
<link rel="alternate" type="application/rss+xml" title="Baldwin" href="{FEED_URL}"></head><body></body></html>"""


def rss(title: str = "Baldwin", items: tuple[tuple[str, str, str], ...] = ()) -> bytes:
    entries = "".join(
        f"<item><title>{name}</title><link>{link}</link><guid>{link}</guid>"
        f"<pubDate>{date}</pubDate><description>{name} in full.</description></item>"
        for name, link, date in items
    )
    return f"""<?xml version="1.0"?><rss version="2.0"><channel><title>{title}</title>
<link>https://www.bensouthwood.co.uk</link><description>We can make things better</description>
<image><url>https://cdn.example.com/baldwin.png</url><title>{title}</title><link>https://www.bensouthwood.co.uk</link></image>
{entries}</channel></rss>""".encode()


ITEMS = (
    ("Post B", "https://www.bensouthwood.co.uk/p/post-b", "Tue, 01 Sep 2026 09:00:00 +0000"),
    ("Post A", "https://www.bensouthwood.co.uk/p/post-a", "Mon, 24 Aug 2026 09:00:00 +0000"),
    ("Post Zero", "https://www.bensouthwood.co.uk/p/post-zero", "Mon, 03 Aug 2026 09:00:00 +0000"),
)


@pytest.fixture
def substack_site(respx_mock):
    respx_mock.get(f"{SITE}/").respond(content=HOMEPAGE, content_type="text/html")
    route = respx_mock.get(FEED_URL).respond(content=rss(items=ITEMS), content_type="application/rss+xml")
    respx_mock.route(host="bensouthwood.substack.com").respond(404)
    respx_mock.route(host="www.bensouthwood.co.uk").respond(404)
    return route


async def newsletter(session, user, sender="bensouthwood@substack.com", title="Ben Southwood", subscribed=True):
    feed = Feed(
        url=f"email://{user.id}/{sender}/{title.lower().replace(' ', '-')}",
        title=title,
        description=sender,
        source=FEED_SOURCE_EMAIL,
        owner_user_id=user.id,
        approval=APPROVAL_APPROVED,
    )
    feed.episodes = [
        Episode(
            guid="issue-a",
            title="Post A",
            content_html="<p>Post A as emailed.</p>",
            link="https://email.mg.substack.com/c/track-a",
            published_at=utcnow() - timedelta(days=9),
        )
    ]
    session.add(feed)
    await session.flush()
    if subscribed:
        session.add(Subscription(user_id=user.id, feed_id=feed.id, latest_after_episode_id=None))
    await session.commit()
    return feed


class TestLinking:
    async def test_a_substack_sender_names_its_own_site(self, session, user, substack_site):
        feed = await newsletter(session, user)

        companion = await companions.attach_companion(session, feed)

        assert companion is not None and companion.url == FEED_URL
        assert feed.companion_feed_id == companion.id
        assert feed.companion_checked_at is not None
        # Its name, face and blurb are the publication's now.
        assert feed.title == "Baldwin"
        assert feed.image_url == "https://cdn.example.com/baldwin.png"
        assert feed.site_url == "https://www.bensouthwood.co.uk"
        assert feed.description == "We can make things better"

    async def test_a_senders_domain_counts_only_when_the_feed_is_named_like_the_newsletter(
        self, session, user, respx_mock
    ):
        respx_mock.get("https://anna.test/").respond(
            content=b'<html><head><link rel="alternate" type="application/rss+xml" href="https://anna.test/feed"></head></html>',
            content_type="text/html",
        )
        respx_mock.get("https://anna.test/feed").respond(content=rss(title="Anna's Holiday Photos"))
        respx_mock.route(host="anna.test").respond(404)
        feed = await newsletter(session, user, sender="list@anna.test", title="Words from Anna")

        assert await companions.attach_companion(session, feed) is None
        assert feed.companion_feed_id is None
        assert feed.companion_checked_at is not None
        assert feed.title == "Words from Anna"

    async def test_a_matching_feed_on_the_senders_domain_is_linked(self, session, user, respx_mock):
        respx_mock.get("https://anna.test/").respond(
            content=b'<html><head><link rel="alternate" type="application/rss+xml" href="https://anna.test/feed"></head></html>',
            content_type="text/html",
        )
        respx_mock.get("https://anna.test/feed").respond(content=rss(title="Words from Anna"))
        respx_mock.route(host="anna.test").respond(404)
        feed = await newsletter(session, user, sender="list@anna.test", title="Words from Anna")

        assert await companions.attach_companion(session, feed) is not None

    async def test_the_site_she_was_signed_up_on_is_trusted(self, session, user, substack_site):
        # A sender at a shared mail domain says nothing; the signup does.
        feed = await newsletter(session, user, sender="hello@gmail.com", title="Baldwin")

        companion = await companions.attach_companion(session, feed, signup_site=SITE)

        assert companion is not None and feed.companion_feed_id == companion.id

    async def test_a_shared_mail_domain_alone_is_not_a_site(self, session, user):
        feed = await newsletter(session, user, sender="news@mail.beehiiv.com", title="Capital Gains")

        assert companions.candidate_sites(feed) == []

    async def test_the_sender_is_read_from_the_private_url(self, session, user):
        feed = await newsletter(session, user, sender="matthewyglesias@substack.com", title="Matthew Yglesias")

        assert companions.sender_address(feed) == "matthewyglesias@substack.com"
        assert companions.candidate_sites(feed) == [("https://matthewyglesias.substack.com", False)]

    async def test_a_substack_list_id_names_its_own_site(self, session, user, substack_site):
        # What Substack really sends: a List-ID of <bensouthwood.substack.com>,
        # which becomes the key on its own — no address in it at all.
        feed = await newsletter(session, user, sender="bensouthwood.substack.com", title="Ben Southwood from Baldwin")

        assert companions.sender_address(feed) is None
        assert companions.list_host(feed) == "bensouthwood.substack.com"
        assert companions.candidate_sites(feed) == [(SITE, False)]
        companion = await companions.attach_companion(session, feed)
        assert companion is not None and feed.companion_feed_id == companion.id
        assert feed.title == "Baldwin"

    async def test_a_list_id_host_is_a_site_only_when_named_like_the_newsletter(self, session, user):
        feed = await newsletter(session, user, sender="news.anna.test", title="Words from Anna")

        assert companions.candidate_sites(feed) == [("https://news.anna.test", True)]

    async def test_a_mailing_platforms_list_id_is_not_a_site(self, session, user):
        for key in ("abc123def.list-id.mcsv.net", "capital-gains.mail.beehiiv.com", "0123abcd"):
            feed = await newsletter(session, user, sender=key, title=f"Newsletter {key}")

            assert companions.candidate_sites(feed) == [], key


class TestTheSweep:
    async def test_links_what_is_due_and_leaves_what_was_checked(self, session, user, substack_site):
        due = await newsletter(session, user)
        checked = await newsletter(session, user, sender="list@quiet.test", title="Quiet")
        checked.companion_checked_at = utcnow()
        await session.commit()

        linked = await companions.attach_missing_companions(session)

        assert linked == 1
        assert due.companion_feed_id is not None
        assert checked.companion_feed_id is None

    async def test_a_signups_site_is_used_by_the_sweep(self, session, user, substack_site):
        feed = await newsletter(session, user, sender="hello@gmail.com", title="Baldwin")
        session.add(
            NewsletterSignup(
                user_id=user.id,
                site_url=SITE,
                publication="Baldwin",
                platform="substack",
                expected_senders="bensouthwood.substack.com",
                feed_id=feed.id,
                completed_at=utcnow(),
            )
        )
        await session.commit()

        assert await companions.attach_missing_companions(session) == 1
        assert feed.companion_feed_id is not None

    async def test_looks_again_after_the_retry_window(self, session, user, substack_site):
        feed = await newsletter(session, user)
        feed.companion_checked_at = utcnow() - timedelta(days=settings.newsletter_companion_retry_days + 1)
        await session.commit()

        assert await companions.attach_missing_companions(session) == 1


class TestWhatSheSees:
    async def test_the_page_shows_her_issues_and_the_archive_once_each(self, client, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)

        rows = (await client.get(f"/feeds/{feed.id}/episodes")).json()

        assert [row["title"] for row in rows] == ["Post B", "Post A", "Post Zero"]
        # Her copy of Post A, not the feed's: it is the one she was sent.
        post_a = next(row for row in rows if row["title"] == "Post A")
        assert post_a["link"] == "https://email.mg.substack.com/c/track-a"
        assert all(row["feed_title"] == "Baldwin" for row in rows)

    async def test_latest_shows_only_what_was_emailed(self, client, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)

        latest = (await client.get("/episodes")).json()

        assert [row["title"] for row in latest] == ["Post A"]

    async def test_the_feed_wears_the_publications_artwork(self, client, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)

        shows = (await client.get("/feeds")).json()

        assert shows[0]["title"] == "Baldwin"
        assert shows[0]["image_url"] == "https://cdn.example.com/baldwin.png"
        assert shows[0]["source"] == "email"

    async def test_the_count_is_what_her_page_shows(self, client, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)

        shows = (await client.get("/feeds")).json()
        page = (await client.get(f"/feeds/{feed.id}/episodes")).json()

        # Her one issue and the feed's three posts, with Post A counted once.
        assert shows[0]["episode_count"] == len(page) == 3
        assert shows[0]["is_article_feed"] is True

    async def test_searching_the_page_covers_the_archive(self, client, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)

        rows = (await client.get(f"/feeds/{feed.id}/episodes", params={"q": "zero"})).json()

        assert [row["title"] for row in rows] == ["Post Zero"]


class TestDuplicates:
    def test_the_feeds_copy_of_an_emailed_post_is_dropped(self):
        own = Episode(feed_id=1, guid="1", title="The Budget, Explained!", link="https://t/track")
        same = Episode(feed_id=2, guid="2", title="The Budget — Explained", link="https://site/p/budget")
        other = Episode(feed_id=2, guid="3", title="Something Else", link="https://site/p/else")

        kept = companions.without_duplicates([own, same, other], own_feed_id=1)

        assert kept == [own, other]

    def test_a_shared_link_is_the_same_post_too(self):
        own = Episode(feed_id=1, guid="1", title="Issue 12", link="https://site/p/twelve")
        same = Episode(feed_id=2, guid="2", title="Twelve", link="https://site/p/twelve")

        assert companions.without_duplicates([own, same], own_feed_id=1) == [own]


class TestBackgroundWork:
    async def test_the_companion_is_polled_though_nobody_subscribes_to_it(self, session, user, substack_site):
        feed = await newsletter(session, user)
        await companions.attach_companion(session, feed)
        substack_site.respond(content=rss(title="Baldwin, renamed", items=ITEMS), content_type="application/rss+xml")

        summary = await poll_all_feeds(session)

        assert summary.polled == 1 and summary.failed == 0
        # And the newsletter takes the companion's latest name with it.
        await session.refresh(feed)
        assert feed.title == "Baldwin, renamed"

    async def test_the_companion_is_never_pruned_as_an_orphan(self, session, user, substack_site):
        feed = await newsletter(session, user)
        companion = await companions.attach_companion(session, feed)
        assert companion is not None

        pruned = await prune_orphaned_feeds(session, now=utcnow() + timedelta(days=365))

        assert pruned == 0
        assert await session.get(Feed, companion.id) is not None

    async def test_leaving_the_newsletter_keeps_the_shared_feed(self, session, user, substack_site):
        feed = await newsletter(session, user)
        companion = await companions.attach_companion(session, feed)
        assert companion is not None

        await feed_service.unsubscribe(session, feed.id, user)

        assert await session.get(Feed, feed.id) is None
        assert await session.get(Feed, companion.id) is not None
        assert (await session.scalars(select(Episode).where(Episode.feed_id == companion.id))).all() != []
