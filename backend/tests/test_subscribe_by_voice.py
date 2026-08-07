from sqlalchemy import func, select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Feed

SEARCH_URL = "https://itunes.apple.com/search"
FEED_URL = "https://feeds.megaphone.fm/GLT4787413333"


def itunes(*shows: dict) -> dict:
    return {"resultCount": len(shows), "results": list(shows)}


def show(name: str, feed: str = FEED_URL) -> dict:
    return {
        "collectionName": name,
        "artistName": "Goalhanger",
        "feedUrl": feed,
        "trackCount": 967,
    }


def subscribe_decision(query: str) -> dict:
    return {"action": "subscribe", "search_query": query, "spoken_response": ""}


class TestSubscribeByVoice:
    async def test_subscribes_to_the_matching_show(self, session, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Rest Is History")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(subscribe_decision("the rest is history"))

        result = await service.interpret(
            session, llm, transcript="subscribe to the rest is history"
        )

        assert result.action == Action.SUBSCRIBED
        feed = await session.scalar(select(Feed))
        assert feed is not None
        assert feed.url == FEED_URL

    async def test_says_which_show_it_added(self, session, respx_mock, podcast_xml):
        # She cannot see the screen, so the name it heard must be read back.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The Rest Is History")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(subscribe_decision("the rest is history"))

        result = await service.interpret(session, llm, transcript="subscribe to it")

        assert "The Rest Is History" in result.spoken_response

    async def test_episodes_are_available_immediately(self, session, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(subscribe_decision("the history hour"))

        await service.interpret(session, llm, transcript="subscribe to the history hour")

        candidates = await service.build_candidates(session)
        assert len(candidates) == 3

    async def test_no_match_is_explained_not_silently_ignored(self, session, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        llm = FakeLLMClient(subscribe_decision("a show that does not exist"))

        result = await service.interpret(session, llm, transcript="subscribe to nonsense")

        assert result.action == Action.UNKNOWN
        assert "a show that does not exist" in result.spoken_response.lower()

    async def test_already_subscribed_says_so(self, session, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(subscribe_decision("the history hour"))

        await service.interpret(session, llm, transcript="subscribe to the history hour")
        result = await service.interpret(session, llm, transcript="subscribe to the history hour")

        assert "already" in result.spoken_response.lower()
        assert await session.scalar(select(func.count()).select_from(Feed)) == 1

    async def test_missing_query_does_not_search(self, session, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes())
        llm = FakeLLMClient({"action": "subscribe", "spoken_response": "?"})

        result = await service.interpret(session, llm, transcript="subscribe")

        assert result.action == Action.UNKNOWN
        assert not route.called

    async def test_unreachable_feed_is_reported_aloud(self, session, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Broken Feed Show")))
        respx_mock.get(FEED_URL).respond(status_code=500)
        llm = FakeLLMClient(subscribe_decision("broken feed show"))

        result = await service.interpret(session, llm, transcript="subscribe to broken feed show")

        assert result.action == Action.UNKNOWN
        assert result.spoken_response

    async def test_directory_outage_is_reported_aloud(self, session, respx_mock):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        llm = FakeLLMClient(subscribe_decision("anything"))

        result = await service.interpret(session, llm, transcript="subscribe to anything")

        assert result.action == Action.UNKNOWN
        assert result.spoken_response


class TestSubscribeDoesNotBreakPlayback:
    async def test_playing_still_works_with_the_larger_action_set(
        self, session, respx_mock, podcast_xml
    ):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        await service.interpret(
            session,
            FakeLLMClient(subscribe_decision("the history hour")),
            transcript="subscribe to the history hour",
        )

        episodes = await service.build_candidates(session)
        play = FakeLLMClient(
            {"action": "play_episode", "episode_id": episodes[0].id, "spoken_response": "Playing."}
        )
        result = await service.interpret(session, play, transcript="play the latest one")

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
