import json
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from audioreader.commands import clarifications, selection
from audioreader.commands.conversation import ConversationFinished, _execute_tool, converse
from audioreader.commands.intents import Action, CommandStatus
from audioreader.llm.openai_responses import ResponseCompleted
from audioreader.models import Episode, Feed, Subscription, User, VoiceClarification, utcnow
from audioreader.schemas import CommandRequest


class Script:
    def __init__(self, *calls):
        self.calls = list(calls)
        self.requests = []

    async def stream(self, **kwargs):
        self.requests.append({**kwargs, "input_items": list(kwargs["input_items"])})
        name, args = self.calls.pop(0)
        yield ResponseCompleted(
            {"output": [{"type": "function_call", "name": name, "call_id": "call", "arguments": json.dumps(args)}]}
        )


async def turn(session, user, client, transcript, **kwargs):
    events = [event async for event in converse(session, client, user=user, transcript=transcript, **kwargs)]
    return next(event.result for event in events if isinstance(event, ConversationFinished))


async def two_shows(session, user):
    feeds = [Feed(title=f"The Rest Is {name}", url=f"https://example.test/{name}") for name in ("History", "Politics")]
    session.add_all(feeds)
    await session.flush()
    session.add_all([Subscription(user_id=user.id, feed_id=feed.id) for feed in feeds])
    await session.commit()
    return feeds


@pytest.mark.parametrize("answer", ["Politics", "the second one"])
async def test_two_turn_unsubscribe_is_answerable_without_a_model(session, user, answer):
    history, politics = await two_shows(session, user)
    client = Script()
    first = await turn(session, user, client, "Unsubscribe from The Rest Is")
    assert first.status is CommandStatus.NEEDS_CLARIFICATION
    assert first.expects_reply
    assert [choice.label for choice in first.clarification.choices] == [history.title, politics.title]
    assert len(list(await session.scalars(select(Subscription)))) == 2
    # Reordering catalogue labels cannot change the saved ordinal/identity.
    politics.title = "A renamed politics show"
    await session.commit()
    second = await turn(session, user, client, answer, clarification_id=first.clarification.id)
    assert second.action is Action.UNSUBSCRIBED
    assert list(await session.scalars(select(Subscription.feed_id))) == [history.id]
    assert not client.requests
    replay = await turn(session, user, client, answer, clarification_id=first.clarification.id)
    assert replay.status is CommandStatus.NOT_FOUND
    assert list(await session.scalars(select(Subscription.feed_id))) == [history.id]


async def test_selected_id_cannot_invent_a_choice(session, user):
    await two_shows(session, user)
    first = await turn(session, user, Script(), "Unsubscribe from The Rest Is")
    second = await turn(
        session, user, Script(), "Politics", clarification_id=first.clarification.id, selected_option_id="99999"
    )
    assert second.clarification.id == first.clarification.id
    assert len(list(await session.scalars(select(Subscription)))) == 2


@pytest.mark.parametrize("state", ["expired", "other_account", "deleted_target"])
async def test_stale_or_foreign_choices_do_not_execute(session, user, state):
    _, politics = await two_shows(session, user)
    first = await turn(session, user, Script(), "Unsubscribe from The Rest Is")
    owner = user
    if state == "expired":
        record = await session.get(VoiceClarification, first.clarification.id)
        record.expires_at = utcnow() - timedelta(seconds=1)
    elif state == "other_account":
        owner = User(display_name="Other")
        session.add(owner)
    else:
        row = await session.scalar(select(Subscription).where(Subscription.feed_id == politics.id))
        await session.delete(row)
    await session.commit()
    second = await turn(session, owner, Script(), "Politics", clarification_id=first.clarification.id)
    assert second.status is CommandStatus.NOT_FOUND
    assert second.action is Action.UNKNOWN


async def test_unclear_yes_keeps_same_question_and_cancel_consumes_it(session, user):
    await two_shows(session, user)
    first = await turn(session, user, Script(), "Unsubscribe from The Rest Is")
    second = await turn(
        session,
        user,
        Script(("resolve_answer", {"choice": "unclear"})),
        "yes",
        clarification_id=first.clarification.id,
    )
    assert second.clarification.id == first.clarification.id
    cancelled = await turn(session, user, Script(), "cancel", clarification_id=first.clarification.id)
    assert not cancelled.expects_reply
    assert len(list(await session.scalars(select(Subscription)))) == 2
    assert await clarifications.load(session, user, first.clarification.id) is None


async def test_new_request_abandons_old_action(session, user):
    await two_shows(session, user)
    first = await turn(session, user, Script(), "Unsubscribe from The Rest Is")
    client = Script(("resolve_answer", {"choice": "new_request"}), ("set_playback_speed", {"speed": 1.5}))
    second = await turn(session, user, client, "Set speed to one and a half", clarification_id=first.clarification.id)
    assert second.action is Action.SET_SPEED
    assert len(list(await session.scalars(select(Subscription)))) == 2


async def test_neither_retains_original_request_for_correction(session, user):
    await two_shows(session, user)
    first = await turn(session, user, Script(), "Unsubscribe from The Rest Is")
    client = Script(("resolve_answer", {"choice": "unclear"}))
    second = await turn(session, user, client, "neither", clarification_id=first.clarification.id)
    assert second.clarification.id != first.clarification.id
    assert not second.clarification.choices
    saved = await clarifications.load(session, user, second.clarification.id)
    assert saved["remaining_request"] == "Unsubscribe from The Rest Is"


async def test_compound_resumes_remaining_steps_after_selection(session, user):
    history, politics = await two_shows(session, user)
    client = Script(
        (
            "ask_clarification",
            {
                "action": "unsubscribe",
                "target_ids": [history.id, politics.id],
                "question": "Which show?",
                "remaining_request": "Set playback speed to 1.5",
            },
        ),
        ("set_playback_speed", {"speed": 1.5}),
    )
    first = await turn(session, user, client, "Unsubscribe from one of these and set speed to 1.5")
    second = await turn(session, user, client, "Politics", clarification_id=first.clarification.id)
    assert [effect.action for effect in second.actions] == [Action.UNSUBSCRIBED, Action.SET_SPEED]
    assert list(await session.scalars(select(Subscription.feed_id))) == [history.id]
    assert "Set playback speed to 1.5" in client.requests[-1]["input_items"][-1]["content"]


def test_dates_use_local_day_and_dst_boundaries():
    now = datetime(2026, 9, 21, 0, 30, tzinfo=UTC)
    start, end = selection.date_bounds("sunday", "America/Los_Angeles", now)
    assert start == datetime(2026, 9, 20, 7, tzinfo=UTC)
    assert end - start == timedelta(days=1)
    start, end = selection.date_bounds("2026-03-29", "Europe/London", now)
    assert end - start == timedelta(hours=23)
    start, end = selection.date_bounds("2026-10-25", "Europe/London", now)
    assert end - start == timedelta(hours=25)
    with pytest.raises(ValueError):
        CommandRequest(transcript="hello", timezone="not/a/timezone")


async def test_date_and_duration_filters_precede_limit_and_latest_selection(session, user):
    feed = (await two_shows(session, user))[1]
    day = datetime(2026, 9, 15, tzinfo=UTC)
    session.add_all(
        [
            Episode(
                feed_id=feed.id,
                guid=str(i),
                title=f"Episode {i}",
                audio_url="https://example.test/a.mp3",
                published_at=day + timedelta(days=1, minutes=i),
                duration_seconds=600,
            )
            for i in range(80)
        ]
    )
    wanted = Episode(
        feed_id=feed.id,
        guid="wanted",
        title="Tuesday",
        audio_url="https://example.test/t.mp3",
        published_at=day + timedelta(hours=15),
        duration_seconds=600,
    )
    unknown = Episode(
        feed_id=feed.id,
        guid="unknown",
        title="Unknown length",
        audio_url="https://example.test/u.mp3",
        published_at=day + timedelta(hours=16),
    )
    session.add_all([wanted, unknown])
    await session.commit()
    args = {
        "feed_id": feed.id,
        "day": "2026-09-15",
        "order": "latest",
        "query": "",
        "unheard": True,
        "saved_only": False,
        "kind": "audio",
        "max_seconds": 1200,
    }
    result = await _execute_tool(
        session,
        name="play_matching_episode",
        arguments=json.dumps(args),
        user=user,
        allowed_episode_ids=set(),
        candidates=[],
        country=None,
    )
    assert result.terminal is not None and result.terminal.episode is not None
    assert result.terminal.episode.id == wanted.id
    args["max_seconds"] = 100
    result = await _execute_tool(
        session,
        name="play_matching_episode",
        arguments=json.dumps(args),
        user=user,
        allowed_episode_ids=set(),
        candidates=[],
        country=None,
    )
    assert result.terminal is not None
    assert result.terminal.status is CommandStatus.NOT_FOUND


async def test_unsupported_seek_does_not_replay_or_dismiss(session, user):
    result = await turn(session, user, Script(), "Skip ahead thirty seconds")
    assert result.status is CommandStatus.UNSUPPORTED
    assert not result.expects_reply
    assert result.episode is None


async def test_normal_speed_is_not_mistaken_for_a_seek(session, user):
    result = await turn(session, user, Script(("set_playback_speed", {"speed": 1})), "Go back to normal speed")
    assert result.action is Action.SET_SPEED
    assert result.speed == 1


async def test_compound_subscription_ambiguity_is_held_before_any_model_or_effect(session, user):
    await two_shows(session, user)
    client = Script()
    first = await turn(session, user, client, "Unsubscribe from The Rest Is and set playback speed to 1.5")
    assert first.clarification is not None
    assert len(list(await session.scalars(select(Subscription)))) == 2
    saved = await clarifications.load(session, user, first.clarification.id)
    assert saved["remaining_request"] == "set playback speed to 1.5"
    assert not client.requests


async def test_latest_cannot_silently_add_a_today_requirement(session, user):
    feed = (await two_shows(session, user))[0]
    result = await _execute_tool(
        session,
        name="play_matching_episode",
        arguments=json.dumps(
            {
                "feed_id": feed.id,
                "day": "today",
                "order": "latest",
                "query": "",
                "kind": None,
                "max_seconds": None,
                "unheard": False,
                "saved_only": False,
            }
        ),
        user=user,
        allowed_episode_ids=set(),
        candidates=[],
        country=None,
        transcript="Play the latest History",
    )
    assert result.terminal is None
    assert not result.output["ok"]
    assert "Latest does not mean today" in result.output["error"]


async def test_calendar_question_cannot_offer_episodes_from_the_wrong_day(session, user):
    from audioreader.commands.intents import Candidate

    old = Candidate(1, "Older Tuesday", "Politics", "", datetime(2020, 1, 7, tzinfo=UTC), 1000)
    result = await _execute_tool(
        session,
        name="ask_clarification",
        arguments=json.dumps(
            {
                "action": "play_episode",
                "target_ids": [old.id],
                "question": "Which Tuesday?",
                "remaining_request": "",
            }
        ),
        user=user,
        allowed_episode_ids={1},
        candidates=[old],
        country=None,
        transcript="Play Tuesday's one",
    )
    assert result.terminal is None
    assert "play_matching_episode" in result.output["error"]


async def test_saved_date_requirement_is_rechecked_when_answered(session, user):
    from audioreader.commands import service

    feed = (await two_shows(session, user))[0]
    day = utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    episodes = [
        Episode(
            feed_id=feed.id,
            guid=str(i),
            title=f"Episode {i}",
            audio_url="https://example.test/a.mp3",
            published_at=day + timedelta(hours=i),
        )
        for i in (1, 2)
    ]
    session.add_all(episodes)
    await session.commit()
    candidates = [await service._now_playing(session, episode.id, user) for episode in episodes]
    first = await clarifications.create(
        session,
        user,
        action="play_episode",
        target_ids=[e.id for e in episodes],
        question="Which?",
        remaining_request="",
        candidates=candidates,
        request="Play today's episode",
        date_window=(day, day + timedelta(days=1)),
    )
    episodes[1].published_at = day - timedelta(days=1)
    await session.commit()
    result = await turn(session, user, Script(), "the second one", clarification_id=first.clarification.id)
    assert result.status is CommandStatus.NOT_FOUND
    assert result.episode is None


def test_additive_migration_preserves_users_and_matches_runtime_schema():
    import importlib.util
    from pathlib import Path

    import sqlalchemy as sa
    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    path = Path(__file__).parents[1] / "alembic/versions/a13d67b4e921_voice_clarifications.py"
    spec = importlib.util.spec_from_file_location("clarification_migration", path)
    assert spec and spec.loader
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    engine = sa.create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(sa.text("CREATE TABLE users (id UUID PRIMARY KEY, display_name TEXT)"))
        connection.execute(sa.text("INSERT INTO users VALUES ('existing', 'Existing user')"))
        with Operations.context(MigrationContext.configure(connection)):
            migration.upgrade()
            actual = {column["name"] for column in sa.inspect(connection).get_columns("voice_clarifications")}
            assert actual == set(VoiceClarification.__table__.columns.keys())
            assert (
                sa.inspect(connection).get_foreign_keys("voice_clarifications")[0]["options"]["ondelete"] == "CASCADE"
            )
            migration.downgrade()
        assert connection.execute(sa.text("SELECT display_name FROM users")).scalar() == "Existing user"
        assert "voice_clarifications" not in sa.inspect(connection).get_table_names()
    engine.dispose()


async def test_identical_episode_titles_offer_distinguishing_dates(session, user):
    from audioreader.commands.intents import Candidate

    candidates = [
        Candidate(i, "Weekly roundup", "Politics", "", datetime(2026, 9, day, tzinfo=UTC), 1200)
        for i, day in ((1, 8), (2, 15))
    ]
    result = await clarifications.create(
        session,
        user,
        action="play_episode",
        target_ids=[1, 2],
        question="Which roundup?",
        remaining_request="",
        candidates=candidates,
        request="Play the roundup",
    )
    assert result.clarification is not None
    assert "8 September 2026" in result.spoken_response
    assert "15 September 2026" in result.spoken_response
    assert clarifications.choice_for(result.clarification, "15 September") == "2"
