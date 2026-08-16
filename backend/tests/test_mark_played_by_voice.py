"""Filing episodes by voice: played, put aside, and put back.

The counterpart to the touch gesture. She cannot see a swipe action, so this
is the only one of the two that works while the episode is playing in her ear.
"""

from datetime import UTC, datetime

import pytest

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.config import settings
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed, PlaybackPosition, Subscription


def filing_decision(action: str, episode_id: int) -> dict:
    return {"action": action, "episode_id": episode_id, "spoken_response": ""}


async def state_of(session, user, episode) -> PlaybackPosition | None:
    return await session.get(PlaybackPosition, (user.id, episode.id))


@pytest.fixture
async def library(session, user):
    feed = Feed(url="https://a.example/feed", title="The Rest Is History")
    feed.episodes = [
        Episode(
            guid=f"trih-{number}",
            title=f"{690 + number}. Elizabeth I vs The Catholics: Killing the Queen (Part {number})",
            audio_url=f"https://cdn/{number}.mp3",
            duration_seconds=4200,
            published_at=datetime(2026, 8, number, tzinfo=UTC),
        )
        for number in (1, 2, 3)
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed.episodes


class TestMarkPlayedByVoice:
    async def test_marks_the_chosen_episode(self, session, user, library):
        llm = FakeLLMClient(filing_decision("mark_played", library[1].id))

        result = await service.interpret(session, llm, user=user, transcript="I've already heard that one")

        assert result.action is Action.MARK_PLAYED
        state = await state_of(session, user, library[1])
        assert state is not None and state.completed is True
        assert state.dismissed is False

    async def test_says_which_episode_it_filed(self, session, user, library):
        # The only check she has on it having picked the right one.
        llm = FakeLLMClient(filing_decision("mark_played", library[1].id))

        result = await service.interpret(session, llm, user=user, transcript="mark this as played")

        assert "Elizabeth" in result.spoken_response

    async def test_the_confirmation_drops_the_episode_number(self, session, user, library):
        llm = FakeLLMClient(filing_decision("mark_played", library[1].id))

        result = await service.interpret(session, llm, user=user, transcript="mark this as played")

        assert "692" not in result.spoken_response

    async def test_it_leaves_the_other_episodes_alone(self, session, user, library):
        llm = FakeLLMClient(filing_decision("mark_played", library[1].id))

        await service.interpret(session, llm, user=user, transcript="mark this as played")

        assert await state_of(session, user, library[0]) is None
        assert await state_of(session, user, library[2]) is None

    async def test_an_episode_it_was_not_offered_is_refused(self, session, user, library):
        # An invented id here changes a row she never mentioned, silently.
        llm = FakeLLMClient(filing_decision("mark_played", 9999))

        result = await service.interpret(session, llm, user=user, transcript="mark this as played")

        assert result.action is Action.UNKNOWN
        assert result.spoken_response


class TestDismissByVoice:
    async def test_puts_the_episode_aside(self, session, user, library):
        llm = FakeLLMClient(filing_decision("dismiss", library[0].id))

        result = await service.interpret(session, llm, user=user, transcript="I'm not interested in that one")

        assert result.action is Action.DISMISS
        state = await state_of(session, user, library[0])
        assert state is not None and state.dismissed is True

    async def test_it_never_claims_she_heard_it(self, session, user, library):
        llm = FakeLLMClient(filing_decision("dismiss", library[0].id))

        await service.interpret(session, llm, user=user, transcript="skip that one")

        state = await state_of(session, user, library[0])
        assert state is not None and state.completed is False


class TestRestoreByVoice:
    async def test_clears_both_flags(self, session, user, library):
        session.add(
            PlaybackPosition(
                user_id=user.id, episode_id=library[0].id, position_seconds=0.0, completed=True, dismissed=True
            )
        )
        await session.commit()
        llm = FakeLLMClient(filing_decision("restore", library[0].id))

        result = await service.interpret(session, llm, user=user, transcript="put that one back")

        assert result.action is Action.RESTORE
        state = await state_of(session, user, library[0])
        assert state is not None
        assert state.completed is False
        assert state.dismissed is False


class TestNowPlaying:
    async def test_it_is_named_in_the_prompt(self, session, user, library):
        # "Mark this as played" is a sentence about something only the phone
        # can see; without this line the honest answer to it is a question.
        llm = FakeLLMClient(filing_decision("mark_played", library[0].id))

        await service.interpret(
            session, llm, user=user, transcript="mark this as played", now_playing_episode_id=library[0].id
        )

        assert "right now" in llm.calls[0]["user"]

    async def test_a_back_catalogue_episode_is_still_choosable(self, session, user, monkeypatch):
        # The candidate list is newest-first and word-matched; an old episode
        # she is in the middle of matches neither, and "mark this as played"
        # names none of its words. Without the now-playing id it would not be
        # in the list at all, and the command could only ask her which one.
        monkeypatch.setattr(settings, "command_candidate_limit", 5)
        feed = Feed(url="https://b.example/feed", title="In Our Time")
        feed.episodes = [
            Episode(
                guid="iot-old",
                title="The Peasants' Revolt",
                audio_url="https://cdn/old.mp3",
                published_at=datetime(2003, 5, 1, tzinfo=UTC),
            ),
            *[
                Episode(
                    guid=f"iot-{number}",
                    title=f"Recent thing {number}",
                    audio_url=f"https://cdn/{number}.mp3",
                    published_at=datetime(2026, 8, number, tzinfo=UTC),
                )
                for number in range(1, 10)
            ],
        ]
        session.add(feed)
        session.add(Subscription(user_id=user.id, feed=feed))
        await session.commit()
        old = feed.episodes[0]
        llm = FakeLLMClient(filing_decision("mark_played", old.id))

        result = await service.interpret(
            session, llm, user=user, transcript="mark this as played", now_playing_episode_id=old.id
        )

        assert result.action is Action.MARK_PLAYED
        assert f"[{old.id}]" in llm.calls[0]["user"]

    async def test_an_unknown_now_playing_id_does_not_break_the_command(self, session, user, library):
        # The phone can be ahead of us, or the episode pruned.
        llm = FakeLLMClient(filing_decision("mark_played", library[0].id))

        result = await service.interpret(
            session, llm, user=user, transcript="mark this as played", now_playing_episode_id=424242
        )

        assert result.action is Action.MARK_PLAYED
