import pytest
from sqlalchemy import func, select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed


def unsubscribe_decision(query: str) -> dict:
    return {"action": "unsubscribe", "search_query": query, "spoken_response": ""}


@pytest.fixture
async def library(session):
    for url, title in [
        ("https://a.example/feed", "The Rest Is History"),
        ("https://b.example/feed", "In Our Time"),
        ("https://c.example/feed", "The Rest Is Politics"),
    ]:
        feed = Feed(url=url, title=title)
        feed.episodes = [
            Episode(guid=f"{title}-1", title=f"{title} ep", audio_url="https://cdn/x.mp3")
        ]
        session.add(feed)
    await session.commit()


class TestUnsubscribeByVoice:
    async def test_removes_the_named_show(self, session, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))

        result = await service.interpret(session, llm, transcript="unsubscribe from in our time")

        assert result.action == Action.UNSUBSCRIBED
        titles = (await session.scalars(select(Feed.title))).all()
        assert "In Our Time" not in titles
        assert len(titles) == 2

    async def test_says_what_it_removed(self, session, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))
        result = await service.interpret(session, llm, transcript="unsubscribe")
        assert "In Our Time" in result.spoken_response

    async def test_removes_that_shows_episodes_too(self, session, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))
        await service.interpret(session, llm, transcript="unsubscribe from in our time")

        remaining = (await session.scalars(select(Episode.title))).all()
        assert not any("In Our Time" in title for title in remaining)

    async def test_matches_a_partial_name(self, session, library):
        llm = FakeLLMClient(unsubscribe_decision("politics"))
        result = await service.interpret(session, llm, transcript="unsubscribe from politics")

        assert result.action == Action.UNSUBSCRIBED
        assert "The Rest Is Politics" in result.spoken_response

    async def test_ambiguous_name_asks_rather_than_guessing(self, session, library):
        # "the rest is" matches two shows. Deleting the wrong one silently
        # would be much worse than asking.
        llm = FakeLLMClient(unsubscribe_decision("the rest is"))

        result = await service.interpret(session, llm, transcript="unsubscribe from the rest is")

        assert result.action == Action.UNKNOWN
        assert await session.scalar(select(func.count()).select_from(Feed)) == 3
        assert "History" in result.spoken_response and "Politics" in result.spoken_response

    async def test_unknown_show_is_explained(self, session, library):
        llm = FakeLLMClient(unsubscribe_decision("gardeners question time"))

        result = await service.interpret(session, llm, transcript="unsubscribe from gardening")

        assert result.action == Action.UNKNOWN
        assert "not subscribed" in result.spoken_response.lower()
        assert await session.scalar(select(func.count()).select_from(Feed)) == 3

    async def test_missing_name_asks_which(self, session, library):
        llm = FakeLLMClient({"action": "unsubscribe", "spoken_response": "?"})

        result = await service.interpret(session, llm, transcript="unsubscribe")

        assert result.action == Action.UNKNOWN
        assert await session.scalar(select(func.count()).select_from(Feed)) == 3

    async def test_nothing_subscribed_says_so(self, session):
        llm = FakeLLMClient(unsubscribe_decision("anything"))
        result = await service.interpret(session, llm, transcript="unsubscribe from anything")
        assert result.action == Action.UNKNOWN
        assert result.spoken_response
