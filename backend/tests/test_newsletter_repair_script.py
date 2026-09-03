"""The operator's way back from a newsletter linked to the wrong feed."""

from scripts.newsletter_repair import newsletters_of, reopen_signup, unlink

from audioreader.models import FEED_SOURCE_EMAIL, Episode, Feed, NewsletterSignup, utcnow


async def test_unlinking_gives_the_sender_its_name_back(session, user):
    companion = Feed(url="https://www.understandingai.org/feed", title="Understanding AI")
    session.add(companion)
    await session.flush()
    feed = Feed(
        url=f"email://{user.id}/astralcodexten.substack.com",
        title="Understanding AI",
        source=FEED_SOURCE_EMAIL,
        owner_user_id=user.id,
        approval="approved",
        companion_feed_id=companion.id,
        companion_latest_after_episode_id=99,
        image_url="https://cdn.example.com/uai.png",
    )
    feed.episodes = [Episode(guid="1", title="Post", author="Astral Codex Ten", published_at=utcnow())]
    session.add(feed)
    await session.commit()
    assert [(f.id, c.id if c else None, a) for f, c, a in await newsletters_of(session, user)] == [
        (feed.id, companion.id, "Astral Codex Ten")
    ]

    await unlink(session, feed)

    assert feed.title == "Astral Codex Ten"
    assert feed.companion_feed_id is None and feed.companion_checked_at is None
    assert feed.companion_latest_after_episode_id is None and feed.image_url is None


async def test_reopening_a_signup_expects_only_its_site(session, user):
    signup = NewsletterSignup(
        user_id=user.id,
        site_url="https://www.understandingai.org",
        publication="Understanding AI",
        platform="substack",
        expected_senders="understandingai.org, substack.com",
        completed_at=utcnow(),
        feed_id=None,
    )
    session.add(signup)
    await session.commit()

    await reopen_signup(session, signup)

    assert signup.completed_at is None and signup.feed_id is None
    assert signup.expected_senders == "understandingai.org"
