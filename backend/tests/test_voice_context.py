"""Exercise the context and tool chain that failed in the Luna comparison."""

import json
from datetime import UTC, datetime

import pytest
from sqlalchemy import select

from audioreader.commands.conversation import ConversationFinished, converse
from audioreader.commands.intents import Action
from audioreader.models import Episode, Feed, PlaybackPosition, Subscription
from evals.jev import parse_input
from test_voice_clarifications import Script, turn


@pytest.fixture
async def shows(session, user, monkeypatch):
    public = Feed(url="https://public.test/feed", title="Public Science")
    followed = Feed(url="https://followed.test/feed", title="My History")
    episodes = [
        Episode(
            feed=feed,
            guid=str(i),
            title=f"Episode {i}",
            audio_url=f"https://audio.test/{i}.mp3",
            published_at=datetime(2026, 9, 22, hour, tzinfo=UTC),
            duration_seconds=1200,
        )
        for i, (feed, hour) in enumerate(((public, 5), (followed, 12)))
    ]
    session.add_all(episodes)
    await session.flush()
    session.add(Subscription(user_id=user.id, feed_id=followed.id))
    await session.commit()

    async def ensure(_session, url):
        return public if url == public.url else followed

    monkeypatch.setattr("audioreader.commands.conversation.feed_service.ensure_feed", ensure)
    return public, followed, episodes


def play(feed_id):
    return {
        "feed_id": feed_id,
        "query": "",
        "order": "latest",
        "day": None,
        "unheard": False,
        "saved_only": False,
        "kind": None,
        "max_seconds": None,
    }


def outputs(request):
    return [
        json.loads(item["output"]) for item in request["input_items"] if item.get("type") == "function_call_output"
    ]


async def test_loaded_show_cannot_silently_broaden_to_library(session, user, shows):
    public, followed, episodes = shows
    client = Script(
        ("load_show_episodes", {"feed_url": public.url, "episode_query": None}),
        ("play_matching_episode", play(None)),
        ("play_matching_episode", play(public.id)),
    )
    result = await turn(session, user, client, "Play the latest Public Science")
    assert result.episode.id == episodes[0].id
    assert outputs(client.requests[2])[-1]["resolved_feed_ids"] == [public.id]
    assert not outputs(client.requests[2])[-1]["ok"]
    assert await session.scalar(select(Subscription.feed_id).where(Subscription.user_id == user.id)) == followed.id

    # Resolution is local to one request. A subsequent library-wide request
    # must not retain the earlier show's constraint.
    next_result = await turn(session, user, Script(("play_matching_episode", play(None))), "Play the latest")
    assert next_result.episode.id == episodes[1].id


async def test_explicit_library_scope_after_lookup_still_works(session, user, shows):
    public, _, episodes = shows
    client = Script(
        ("load_show_episodes", {"feed_url": public.url, "episode_query": None}),
        ("play_matching_episode", play(None)),
    )
    result = await turn(session, user, client, "Check Public Science, then play the latest across my library")
    assert result.episode.id == episodes[1].id


@pytest.mark.parametrize("already_subscribed", [False, True])
async def test_subscription_returns_id_for_direct_scoped_playback(session, user, shows, already_subscribed):
    public, _, episodes = shows
    if already_subscribed:
        session.add(Subscription(user_id=user.id, feed_id=public.id))
        await session.commit()
    client = Script(
        ("subscribe_to_feed", {"feed_url": public.url, "continue_request": True}),
        ("play_matching_episode", play(public.id)),
    )
    result = await turn(session, user, client, "Subscribe to Public Science and play its latest")
    receipt = outputs(client.requests[1])[-1]
    assert receipt["feed_id"] == public.id
    assert receipt["feed_url"] == public.url
    assert receipt["status"] == ("already_subscribed" if already_subscribed else "subscribed")
    assert result.episode.id == episodes[0].id


async def test_context_has_complete_records_and_refreshes_filing_state(session, user, shows):
    _, followed, episodes = shows
    episode = episodes[1]
    session.add(
        PlaybackPosition(user_id=user.id, episode_id=episode.id, completed=True, dismissed=True, position_seconds=123)
    )
    await session.commit()
    client = Script(
        ("file_episode", {"episode_id": episode.id, "action": "restore", "continue_request": True}),
        ("set_playback_speed", {"speed": 1.5}),
    )
    events = [
        event
        async for event in converse(
            session,
            client,
            user=user,
            transcript="Put this back and set speed to 1.5",
            now_playing_episode_id=episode.id,
        )
    ]
    assert any(isinstance(event, ConversationFinished) for event in events)
    content = client.requests[0]["input_items"][-1]["content"]
    record = next(json.loads(line) for line in content.splitlines() if line.startswith("{"))
    assert record["feed_id"] == followed.id
    assert record["feed_title"] == followed.title
    assert record["published_at"] == "2026-09-22T12:00:00+00:00"
    assert record["completed"] and record["dismissed"]
    assert record["position_seconds"] == 123
    assert "Listening details" not in content
    refreshed = outputs(client.requests[1])[-1]["episodes"][0]
    assert not refreshed["completed"] and not refreshed["dismissed"]
    assert refreshed["position_seconds"] == 0
    # The evaluation-only adapter must read the same production context.
    parsed = parse_input(client.requests[0]["input_items"])
    assert parsed["episodes"][str(episode.id)]["published"] == record["published_at"]
    assert parsed["episodes"][str(episode.id)]["latest_overall"]


@pytest.mark.parametrize("completed,dismissed", [(True, False), (False, True), (False, False)])
async def test_explicit_restore_is_idempotent_and_resets_progress(session, user, shows, completed, dismissed):
    episode = shows[2][1]
    session.add(
        PlaybackPosition(
            user_id=user.id, episode_id=episode.id, completed=completed, dismissed=dismissed, position_seconds=123
        )
    )
    await session.commit()
    client = Script(("file_episode", {"episode_id": episode.id, "action": "restore"}))
    result = await turn(session, user, client, "Put this back", now_playing_episode_id=episode.id)
    assert result.action is Action.RESTORE
    state = await session.scalar(select(PlaybackPosition).where(PlaybackPosition.episode_id == episode.id))
    assert (state.completed, state.dismissed, state.position_seconds) == (False, False, 0)
