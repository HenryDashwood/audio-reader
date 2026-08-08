import pytest
from sqlalchemy import func, select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Feed, Subscription


def unsubscribe_decision(query: str) -> dict:
    return {"action": "unsubscribe", "search_query": query, "spoken_response": ""}


async def subscribed_titles(session, user) -> list[str]:
    return list(
        await session.scalars(
            select(Feed.title)
            .join(Subscription, Subscription.feed_id == Feed.id)
            .where(Subscription.user_id == user.id)
        )
    )


@pytest.fixture
async def library(session, user):
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
        session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()


class TestUnsubscribeByVoice:
    async def test_removes_the_named_show(self, session, user, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))

        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from in our time"
        )

        assert result.action == Action.UNSUBSCRIBED
        titles = await subscribed_titles(session, user)
        assert "In Our Time" not in titles
        assert len(titles) == 2

    async def test_feed_stays_in_the_shared_catalog(self, session, user, library):
        # Unsubscribing is personal: the feed and its episodes must survive
        # for other subscribers and for instant re-subscribing.
        llm = FakeLLMClient(unsubscribe_decision("in our time"))

        await service.interpret(session, llm, user=user, transcript="unsubscribe from in our time")

        assert await session.scalar(select(func.count()).select_from(Feed)) == 3
        remaining = (await session.scalars(select(Episode.title))).all()
        assert any("In Our Time" in title for title in remaining)

    async def test_says_what_it_removed(self, session, user, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))
        result = await service.interpret(session, llm, user=user, transcript="unsubscribe")
        assert "In Our Time" in result.spoken_response

    async def test_its_episodes_are_no_longer_offered(self, session, user, library):
        llm = FakeLLMClient(unsubscribe_decision("in our time"))
        await service.interpret(session, llm, user=user, transcript="unsubscribe from in our time")

        candidates = await service.build_candidates(session, user)
        assert not any("In Our Time" in candidate.feed_title for candidate in candidates)

    async def test_matches_a_partial_name(self, session, user, library):
        llm = FakeLLMClient(unsubscribe_decision("politics"))
        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from politics"
        )

        assert result.action == Action.UNSUBSCRIBED
        assert "The Rest Is Politics" in result.spoken_response

    async def test_ambiguous_name_asks_rather_than_guessing(self, session, user, library):
        # "the rest is" matches two shows. Deleting the wrong one silently
        # would be much worse than asking.
        llm = FakeLLMClient(unsubscribe_decision("the rest is"))

        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from the rest is"
        )

        assert result.action == Action.UNKNOWN
        assert len(await subscribed_titles(session, user)) == 3
        assert "History" in result.spoken_response and "Politics" in result.spoken_response

    async def test_unknown_show_is_explained(self, session, user, library):
        llm = FakeLLMClient(unsubscribe_decision("gardeners question time"))

        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from gardening"
        )

        assert result.action == Action.UNKNOWN
        assert "not subscribed" in result.spoken_response.lower()
        assert len(await subscribed_titles(session, user)) == 3

    async def test_missing_name_asks_which(self, session, user, library):
        llm = FakeLLMClient({"action": "unsubscribe", "spoken_response": "?"})

        result = await service.interpret(session, llm, user=user, transcript="unsubscribe")

        assert result.action == Action.UNKNOWN
        assert len(await subscribed_titles(session, user)) == 3

    async def test_nothing_subscribed_says_so(self, session, user):
        llm = FakeLLMClient(unsubscribe_decision("anything"))
        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from anything"
        )
        assert result.action == Action.UNKNOWN
        assert result.spoken_response

    async def test_another_users_show_is_not_removable(self, session, user, library):
        # A show only someone else subscribes to must look unknown to this user.
        from audioreader.models import User

        other = User(display_name="Other")
        other_feed = Feed(url="https://d.example/feed", title="Gardeners Question Time")
        session.add_all([other, other_feed])
        await session.flush()
        session.add(Subscription(user_id=other.id, feed_id=other_feed.id))
        await session.commit()

        llm = FakeLLMClient(unsubscribe_decision("gardeners question time"))
        result = await service.interpret(
            session, llm, user=user, transcript="unsubscribe from gardeners question time"
        )

        assert result.action == Action.UNKNOWN
        assert "not subscribed" in result.spoken_response.lower()
        assert await session.scalar(select(func.count()).select_from(Subscription)) == 4
