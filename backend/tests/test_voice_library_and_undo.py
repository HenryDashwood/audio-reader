from sqlalchemy import select

from audioreader.commands import library, undo
from audioreader.commands.intents import Action
from audioreader.models import Episode, Feed, PlaybackPosition, Subscription
from audioreader.positions import set_episode_state


async def test_library_filters_before_limiting_candidates(session, user):
    feed = Feed(url="https://example.test/feed", title="A show")
    session.add(feed)
    await session.flush()
    session.add(Subscription(user_id=user.id, feed_id=feed.id))
    episodes = [
        Episode(
            feed=feed,
            guid=str(i),
            title=f"Topic {i}",
            audio_url=f"https://example.test/{i}.mp3",
            duration_seconds=seconds,
        )
        for i, seconds in enumerate([600, 1800, None, 800])
    ]
    session.add_all(episodes)
    await session.commit()
    await set_episode_state(session, user, episodes[3].id, played=True)
    selected = await library.search(session, user, query="", unheard=True, kind="audio", max_seconds=1200)
    assert [item.id for item in selected] == [episodes[0].id]


async def test_undo_restores_exact_filing_state_and_position(session, user):
    feed = Feed(url="https://example.test/feed", title="A show")
    episode = Episode(feed=feed, guid="one", title="An episode", audio_url="https://example.test/one.mp3")
    session.add(episode)
    await session.commit()
    position = PlaybackPosition(
        user_id=user.id, episode_id=episode.id, position_seconds=123, completed=False, dismissed=False
    )
    session.add(position)
    await session.commit()
    before = await undo.snapshot(session, user, "file_episode", {"episode_id": episode.id})
    await set_episode_state(session, user, episode.id, dismissed=True)
    await undo.remember(session, user, before)
    result = await undo.undo_last(session, user)
    assert result.action == Action.RESTORE
    assert position.position_seconds == 123
    assert not position.dismissed
    assert (await undo.undo_last(session, user)).action == Action.UNKNOWN


async def test_undo_does_not_overwrite_a_later_change(session, user):
    feed = Feed(url="https://example.test/feed", title="A show")
    episode = Episode(feed=feed, guid="one", title="An episode", audio_url="https://example.test/one.mp3")
    session.add(episode)
    await session.commit()
    before = await undo.snapshot(session, user, "file_episode", {"episode_id": episode.id})
    await set_episode_state(session, user, episode.id, dismissed=True)
    await undo.remember(session, user, before)
    await set_episode_state(session, user, episode.id, played=True)
    assert (await undo.undo_last(session, user)).action == Action.UNKNOWN


async def test_undo_subscription_removes_only_the_subscription(session, user):
    feed = Feed(url="https://example.test/feed", title="A show")
    session.add(feed)
    await session.commit()
    before = await undo.snapshot(session, user, "subscribe_to_feed", {})
    session.add(Subscription(user_id=user.id, feed_id=feed.id))
    await session.commit()
    await undo.remember(session, user, before)
    assert (await undo.undo_last(session, user)).action == Action.UNSUBSCRIBED
    assert await session.get(Feed, feed.id) is not None


async def test_undo_unsubscribe_restores_the_latest_feed_cursor(session, user):
    feed = Feed(url="https://example.test/feed", title="A show")
    episode = Episode(feed=feed, guid="one", title="An episode", audio_url="https://example.test/one.mp3")
    session.add(episode)
    await session.commit()
    subscription = Subscription(user_id=user.id, feed_id=feed.id, latest_after_episode_id=episode.id)
    session.add(subscription)
    await session.commit()
    before = await undo.snapshot(session, user, "unsubscribe_from_feed", {"feed_id": feed.id})
    await session.delete(subscription)
    await session.commit()
    await undo.remember(session, user, before)

    assert (await undo.undo_last(session, user)).action == Action.SUBSCRIBED
    restored = await session.scalar(
        select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed.id)
    )
    assert restored.latest_after_episode_id == episode.id
