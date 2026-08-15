"""Playing an episode of a show she is not subscribed to."""

from sqlalchemy import func, select

from audioreader.commands import service
from audioreader.commands.intents import Action
from audioreader.feeds import service as feed_service
from audioreader.llm.fake import FakeLLMClient
from audioreader.models import Episode, Subscription

SEARCH_URL = "https://itunes.apple.com/search"
FEED_URL = "https://feeds.megaphone.fm/GLT4787413333"


def itunes(*shows: dict) -> dict:
    return {"resultCount": len(shows), "results": list(shows)}


def show(name: str, feed: str = FEED_URL) -> dict:
    return {
        "collectionName": name,
        "artistName": "BBC",
        "feedUrl": feed,
        "trackCount": 103,
    }


def play_from_show(query: str, episode_query: str | None = None) -> dict:
    return {
        "action": "play_from_show",
        "search_query": query,
        "episode_query": episode_query,
        "spoken_response": "",
    }


class TestPlayLatest:
    async def test_plays_the_newest_episode(self, session, user, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(play_from_show("the history hour"))

        result = await service.interpret(session, llm, user=user, transcript="play the latest history hour")

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.title == "The Fall of Constantinople"

    async def test_names_the_show_aloud(self, session, user, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(play_from_show("the history hour"))

        result = await service.interpret(session, llm, user=user, transcript="play the latest history hour")

        assert "The History Hour" in result.spoken_response

    async def test_latest_needs_no_second_model_call(self, session, user, respx_mock, podcast_xml):
        # "Play the latest X" is by far the common case; it must cost one
        # model call, not two.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(play_from_show("the history hour", "the latest one"))

        result = await service.interpret(session, llm, user=user, transcript="play the latest history hour")

        assert result.action == Action.PLAY_EPISODE
        assert len(llm.calls) == 1

    async def test_does_not_subscribe_her(self, session, user, respx_mock, podcast_xml):
        # Asking to hear one episode is not asking to follow the show.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        llm = FakeLLMClient(play_from_show("the history hour"))

        await service.interpret(session, llm, user=user, transcript="play the latest history hour")

        assert await session.scalar(select(func.count()).select_from(Subscription)) == 0


class TestPlayDescribedEpisode:
    async def test_second_call_picks_from_that_show_only(self, session, user, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        # Feed already in the catalog (another user subscribed, say), so its
        # episode ids are knowable up front.
        respx_mock.get(FEED_URL).respond(content=podcast_xml)
        await feed_service.ensure_feed(session, FEED_URL)
        wanted = await session.scalar(select(Episode).where(Episode.title == "The South Sea Bubble"))

        llm = FakeLLMClient()
        llm.queue(
            play_from_show("the history hour", "the one about the south sea bubble"),
            {
                "action": "play_episode",
                "episode_id": wanted.id,
                "spoken_response": "Playing the South Sea Bubble.",
            },
        )

        result = await service.interpret(
            session,
            llm,
            user=user,
            transcript="play the history hour episode about the south sea bubble",
        )

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.id == wanted.id
        assert result.spoken_response == "Playing the South Sea Bubble."
        # The second call reads a different, smaller prompt: one show's list.
        assert len(llm.calls) == 2
        assert llm.calls[1]["system"] == service.EPISODE_PICK_PROMPT
        assert "South Sea Bubble" in llm.calls[1]["user"]

    async def test_invented_episode_id_is_rejected(self, session, user, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)

        llm = FakeLLMClient()
        llm.queue(
            play_from_show("the history hour", "the one about agincourt"),
            {"action": "play_episode", "episode_id": 999999, "spoken_response": "Playing."},
        )

        result = await service.interpret(
            session, llm, user=user, transcript="play the history hour one about agincourt"
        )

        assert result.action == Action.UNKNOWN
        assert result.spoken_response

    async def test_no_match_reads_the_models_question(self, session, user, respx_mock, podcast_xml):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("The History Hour")))
        respx_mock.get(FEED_URL).respond(content=podcast_xml)

        llm = FakeLLMClient()
        llm.queue(
            play_from_show("the history hour", "the one about knitting"),
            {"action": "unknown", "spoken_response": "Which topic was it about?"},
        )

        result = await service.interpret(
            session, llm, user=user, transcript="play the history hour one about knitting"
        )

        assert result.action == Action.UNKNOWN
        assert result.spoken_response == "Which topic was it about?"


class TestFailuresAreSpoken:
    async def test_unknown_show_is_named(self, session, user, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes())
        llm = FakeLLMClient(play_from_show("a show that does not exist"))

        result = await service.interpret(session, llm, user=user, transcript="play nonsense")

        assert result.action == Action.UNKNOWN
        assert "a show that does not exist" in result.spoken_response.lower()

    async def test_directory_outage_is_reported(self, session, user, respx_mock):
        respx_mock.get(SEARCH_URL).respond(status_code=503)
        llm = FakeLLMClient(play_from_show("anything"))

        result = await service.interpret(session, llm, user=user, transcript="play anything")

        assert result.action == Action.UNKNOWN
        assert result.spoken_response

    async def test_unreachable_feed_is_reported(self, session, user, respx_mock):
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Broken Feed Show")))
        respx_mock.get(FEED_URL).respond(status_code=500)
        llm = FakeLLMClient(play_from_show("broken feed show"))

        result = await service.interpret(session, llm, user=user, transcript="play the latest broken feed show")

        assert result.action == Action.UNKNOWN
        assert "Broken Feed Show" in result.spoken_response

    async def test_article_feeds_play_their_latest_article(self, session, user, respx_mock, article_xml):
        # A feed with no audio is still playable: the app reads articles aloud.
        respx_mock.get(SEARCH_URL).respond(json=itunes(show("Notes on Progress")))
        respx_mock.get(FEED_URL).respond(content=article_xml)
        llm = FakeLLMClient(play_from_show("notes on progress"))

        result = await service.interpret(session, llm, user=user, transcript="play the latest notes on progress")

        assert result.action == Action.PLAY_EPISODE
        assert result.episode is not None
        assert result.episode.title == "Why sewers made cities possible"
        assert result.episode.audio_url is None

    async def test_missing_show_name_asks_for_it(self, session, user, respx_mock):
        route = respx_mock.get(SEARCH_URL).respond(json=itunes())
        llm = FakeLLMClient({"action": "play_from_show", "spoken_response": ""})

        result = await service.interpret(session, llm, user=user, transcript="play it")

        assert result.action == Action.UNKNOWN
        assert not route.called


class TestWantsLatest:
    def test_nothing_specific_means_latest(self):
        for query in (
            None,
            "",
            "  ",
            "latest",
            "the latest",
            "the latest one",
            "newest episode",
            "the most recent one",
            "their last episode",
        ):
            assert service._wants_latest(query), query

    def test_a_described_episode_goes_to_the_model(self):
        for query in ("the one about agincourt", "tuesday's", "the diana pasulka one"):
            assert not service._wants_latest(query), query
