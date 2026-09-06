"""Several independently polled sources can form one listener's publication."""

from datetime import timedelta

import pytest
from sqlalchemy import select

from audioreader.commands import library
from audioreader.commands import service as commands
from audioreader.feeds import groups
from audioreader.models import Episode, Feed, Subscription, User, utcnow


async def source(session, user, name, posts):
    feed = Feed(url=f"https://{name}.test/feed", title=name, site_artwork_checked_at=utcnow())
    session.add(feed)
    await session.flush()
    episodes = []
    for i, (title, link, body) in enumerate(posts):
        item = Episode(
            feed_id=feed.id,
            guid=f"{name}-{i}",
            title=title,
            link=link,
            content_html=body,
            published_at=utcnow() - timedelta(days=i),
        )
        session.add(item)
        episodes.append(item)
    session.add(Subscription(user_id=user.id, feed_id=feed.id))
    await session.commit()
    return feed, episodes


@pytest.fixture
async def pair(session, user):
    private, own = await source(
        session,
        user,
        "subscriber",
        [
            (
                "Shared article",
                "https://publisher.test/story/?access_token=subscriber-access",
                "<p>Full article. " + "Words " * 100 + "</p>",
            ),
            ("Subscriber only", "https://publisher.test/private", "Private text"),
        ],
    )
    public, public_items = await source(
        session,
        user,
        "public",
        [
            ("Shared article", "http://publisher.test/story?utm_source=rss#top", "Preview"),
            ("Public interview", "https://publisher.test/interview", "An interview"),
            ("Paywalled preview", "https://publisher.test/paywalled", "Short preview"),
        ],
    )
    return private, public, own, public_items


async def combine(client, pair):
    root, other, _, _ = pair
    response = await client.put(f"/feeds/{root.id}/sources/{other.id}")
    assert response.status_code == 204, response.text


async def test_combines_counts_and_pages_but_keeps_previews(client, session, pair):
    await combine(client, pair)
    root, other, own, public = pair
    feeds = (await client.get("/feeds")).json()
    assert len(feeds) == 1
    assert feeds[0]["id"] == root.id
    assert feeds[0]["episode_count"] == 4
    assert {s["id"] for s in feeds[0]["sources"]} == {root.id, other.id}
    page = (await client.get(f"/feeds/{root.id}/episodes")).json()
    assert {item["id"] for item in page} == {own[0].id, own[1].id, public[1].id, public[2].id}
    assert {item["feed_title"] for item in page} == {root.title}
    # Source records, identifiers and subscriptions remain intact.
    assert len(list(await session.scalars(select(Subscription)))) == 2
    assert len(list(await session.scalars(select(Episode)))) == 5
    assert (await session.get(Episode, own[0].id)).link == (
        "https://publisher.test/story/?access_token=subscriber-access"
    )
    preview = (await client.post("/feeds/preview", json={"url": other.url})).json()
    assert preview["feed"]["id"] == root.id
    assert preview["feed"]["episode_count"] == 4
    assert len(preview["episodes"]) == 4


async def test_prefers_richer_secondary_copy_and_dedupes_before_limit(client, session, user):
    root, own = await source(
        session,
        user,
        "short",
        [
            ("Post", "https://publisher.test/post", "Preview"),
        ],
    )
    other, copies = await source(
        session,
        user,
        "full",
        [
            ("Post", "https://publisher.test/post/", "Full text " * 80),
            ("Another", "https://publisher.test/another", "Body"),
        ],
    )
    await groups.combine(session, user.id, root.id, other.id)
    page = (await client.get(f"/feeds/{root.id}/episodes?limit=2")).json()
    assert [item["id"] for item in page] == [item.id for item in copies]
    search = (await client.get("/search/episodes?q=Post&limit=1")).json()
    assert [item["id"] for item in search] == [copies[0].id]
    assert own[0].id not in {item.id for item in await commands.build_candidates(session, user)}


async def test_groups_are_private_to_listener(client, session, user, make_client, pair):
    root, other, _, _ = pair
    second = User(display_name="Another listener")
    session.add(second)
    await session.flush()
    session.add_all([Subscription(user_id=second.id, feed_id=f.id) for f in (root, other)])
    await session.commit()
    await combine(client, pair)
    async with make_client(second) as other_client:
        assert len((await other_client.get("/feeds")).json()) == 2
        assert len((await other_client.get(f"/feeds/{other.id}/episodes")).json()) == 3
        assert len((await other_client.get(f"/feeds/{root.id}/sources")).json()) == 1
    third = User()
    session.add(third)
    await session.commit()
    async with make_client(third) as stranger:
        assert (await stranger.put(f"/feeds/{root.id}/sources/{other.id}")).status_code == 404
        assert (await stranger.get(f"/feeds/{root.id}/sources")).status_code == 404
        assert (await stranger.delete(f"/feeds/{root.id}/sources/{other.id}")).status_code == 404


async def test_duplicates_share_progress_filing_and_restore(client, session, user, pair):
    root, _, own, public = pair
    await client.put(f"/episodes/{public[0].id}/position", json={"position_seconds": 45, "completed": False})
    await combine(client, pair)
    item = (await client.get(f"/episodes/{own[0].id}")).json()
    assert item["position_seconds"] == 45
    await client.put(f"/episodes/{own[0].id}/state", json={"dismissed": True})
    assert (await client.get(f"/episodes/{public[0].id}")).json()["dismissed"]
    assert own[0].id not in {e["id"] for e in (await client.get("/episodes")).json()}
    # Restoring through either copy overrides an older sibling's dismissal.
    await client.put(f"/episodes/{public[0].id}/state", json={"dismissed": False})
    assert not (await client.get(f"/episodes/{own[0].id}")).json()["dismissed"]
    assert own[0].id in {e["id"] for e in (await client.get("/episodes")).json()}
    await client.put(f"/episodes/{public[0].id}/state", json={"played": True})
    assert own[0].id not in {
        e.id for e in await library.search(session, user, query="Shared", unheard=True, kind=None, max_seconds=None)
    }
    assert (await client.get(f"/feeds/{root.id}/episodes?q=Shared")).json()[0]["completed"]


async def test_late_copy_inherits_state_and_does_not_resurrect_cleared_article(client, session, user, pair):
    root, other, own, _ = pair
    await combine(client, pair)
    await client.put(f"/episodes/{own[1].id}/position", json={"position_seconds": 23, "completed": False})
    assert (await client.delete("/episodes")).status_code == 204
    late = Episode(
        feed_id=other.id,
        guid="late",
        title="Subscriber only",
        link=own[1].link,
        content_html="New richer copy " * 100,
        published_at=utcnow(),
    )
    new = Episode(
        feed_id=other.id,
        guid="new",
        title="New post",
        link="https://publisher.test/new",
        content_html="New",
        published_at=utcnow(),
    )
    session.add_all([late, new])
    await session.commit()
    news = (await client.get("/episodes")).json()
    assert [item["id"] for item in news] == [new.id]
    assert (await client.get(f"/episodes/{late.id}")).json()["position_seconds"] == 23
    page = (await client.get(f"/feeds/{root.id}/episodes?q=Subscriber")).json()
    assert [item["id"] for item in page] == [late.id]


async def test_separating_preserves_state_and_both_subscriptions(client, session, pair):
    root, other, own, public = pair
    await combine(client, pair)
    await client.put(f"/episodes/{own[0].id}/state", json={"played": True})
    assert (await client.delete(f"/feeds/{root.id}/sources/{other.id}")).status_code == 204
    assert len((await client.get("/feeds")).json()) == 2
    assert (await client.get(f"/episodes/{public[0].id}")).json()["completed"]
    assert (await client.get(f"/episodes/{own[0].id}")).json()["completed"]
    assert (await client.delete(f"/feeds/{root.id}/sources/{root.id}")).status_code == 404


async def test_group_merging_is_flat_idempotent_and_cannot_cycle(client, session, user, pair):
    root, other, _, _ = pair
    await combine(client, pair)
    await combine(client, pair)
    assert (await client.put(f"/feeds/{other.id}/sources/{root.id}")).status_code == 409
    assert (await client.put(f"/feeds/{root.id}/sources/{root.id}")).status_code == 409
    third, _ = await source(session, user, "third", [])
    assert (await client.put(f"/feeds/{third.id}/sources/{root.id}")).status_code == 204
    feeds = (await client.get("/feeds")).json()
    assert [f["id"] for f in feeds] == [third.id]
    assert len(feeds[0]["sources"]) == 3


async def test_unsubscribe_removes_whole_group_without_deleting_articles(client, session, pair):
    root, _, _, _ = pair
    await combine(client, pair)
    assert (await client.delete(f"/feeds/{root.id}")).status_code == 204
    assert (await client.get("/feeds")).json() == []
    assert len(list(await session.scalars(select(Episode)))) == 5


@pytest.mark.parametrize(
    ("a", "b", "same"),
    [
        ("https://example.test/post/?utm_source=x#section", "http://EXAMPLE.test/post", True),
        ("https://example.test/post?access_token=private", "https://example.test/post", True),
        ("https://example.test/post?access_token=old", "https://example.test/post?access_token=new", True),
        ("https://example.test/?p=1&access_token=private", "https://example.test/?p=2", False),
        ("https://example.test/?p=1", "https://example.test/?p=2", False),
        ("https://example.test/post?a=1&b=2", "https://example.test/post?b=2&a=1", True),
        ("https://example.test/Post", "https://example.test/post", False),
        ("https://one.test/post", "https://two.test/post", False),
    ],
)
def test_conservative_article_identity(a, b, same):
    assert (groups.article_key(a) == groups.article_key(b)) is same


async def test_titles_and_missing_links_do_not_merge(client, session, user):
    root, _ = await source(session, user, "one", [("Weekly update", None, "One")])
    other, _ = await source(session, user, "two", [("Weekly update", None, "Two")])
    await groups.combine(session, user.id, root.id, other.id)
    assert len((await client.get(f"/feeds/{root.id}/episodes")).json()) == 2


async def test_email_companion_deduplication_survives_explicit_grouping(client, session, user):
    from audioreader.newsletters import service as newsletters

    email, own = await source(
        session,
        user,
        "email",
        [
            ("Shared", "https://tracking.test/email", "Full emailed article " * 30),
        ],
    )
    email.source = "email"
    email.owner_user_id = user.id
    email.approval = "approved"
    companion, copies = await source(
        session,
        user,
        "companion",
        [
            ("Shared", "https://publisher.test/story", "Public preview"),
        ],
    )
    # The automatic companion is normally polled without a subscription.
    companion_sub = await session.scalar(select(Subscription).where(Subscription.feed_id == companion.id))
    await session.delete(companion_sub)
    email.companion_feed_id = companion.id
    extra, _ = await source(session, user, "extra", [("Extra", "https://publisher.test/extra", "Extra body")])
    await groups.combine(session, user.id, email.id, extra.id)
    page = (await client.get(f"/feeds/{email.id}/episodes")).json()
    assert len(page) == 2
    assert own[0].id in {item["id"] for item in page}
    await client.put(f"/episodes/{own[0].id}/state", json={"played": True})
    assert (await client.get(f"/episodes/{copies[0].id}")).json()["completed"]
    assert copies[0].id not in {candidate.id for candidate in await commands.build_candidates(session, user)}
    # Refusing the sender via the newsletter controls releases other sources.
    assert await newsletters.block(session, user, email.id)
    assert [feed["id"] for feed in (await client.get("/feeds")).json()] == [extra.id]


async def test_every_explicit_source_still_polls(client, session, user, pair, respx_mock):
    from audioreader.feeds.poller import poll_all_feeds

    await combine(client, pair)
    root, other, _, _ = pair
    for feed in (root, other):
        respx_mock.get(feed.url).respond(
            content=f"""<rss><channel><title>{feed.title}</title>
            <item><guid>fresh-{feed.id}</guid><title>New {feed.id}</title>
            <link>https://publisher.test/new-{feed.id}</link></item></channel></rss>""".encode()
        )
    summary = await poll_all_feeds(session)
    assert summary.polled == 2
    assert summary.episodes_added == 2
    assert len((await client.get(f"/feeds/{root.id}/episodes")).json()) == 6
