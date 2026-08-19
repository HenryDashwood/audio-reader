"""What the service reports about itself, and what it keeps to itself.

These assert on the telemetry the way the rest of the suite asserts on
responses, for two reasons. Instrumentation is silent when it breaks — a span
that stopped carrying `action` looks exactly like a quiet week — and the
privacy half is a promise made in the published policy, which should fail a
test long before it fails a user.
"""

from datetime import UTC, datetime

import logfire
import pytest
from logfire.testing import CaptureLogfire

from audioreader import telemetry
from audioreader.commands.intents import ModelDecision
from audioreader.config import settings
from audioreader.llm.client import LLMError
from audioreader.llm.openai_compatible import OpenAICompatibleClient
from audioreader.models import Episode, Feed, Subscription

TRANSCRIPT = "play the Vienna episode"
BASE_URL = "https://openrouter.test/api/v1"


@pytest.fixture
async def library(session, user):
    feed = Feed(url="https://example.com/feed.xml", title="The History Hour")
    feed.episodes = [
        Episode(
            guid="ep-104",
            title="The Congress of Vienna",
            audio_url="https://cdn.example.com/104.mp3",
            published_at=datetime(2026, 8, 4, tzinfo=UTC),
        )
    ]
    session.add(feed)
    session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()
    return feed


def command_span(capfire: CaptureLogfire) -> dict:
    """The one span per spoken request that the accuracy work is built on."""
    spans = [span for span in capfire.exporter.exported_spans_as_dict() if span["name"] == "command"]
    assert spans, "no command span was emitted"
    return spans[0]


class TestCommandSpan:
    async def test_records_what_was_decided(self, capfire, client, fake_llm, library):
        fake_llm.respond_with(
            {"action": "play_episode", "episode_id": 1, "spoken_response": "Playing The Congress of Vienna."}
        )
        await client.post("/command", json={"transcript": TRANSCRIPT})

        attributes = command_span(capfire)["attributes"]
        assert attributes["action"] == "play_episode"
        assert attributes["model_action"] == "play_episode"
        assert attributes["episode_id"] == 1
        assert attributes["episode_title"] == "The Congress of Vienna"
        # A plain string rather than a null, so `group by failure` buckets
        # the successes alongside each way of failing.
        assert attributes["failure"] == "none"
        # The size of the choice the model was given. Without it, an episode
        # she named and did not get cannot be told apart from one that was
        # never in the list to begin with.
        assert attributes["candidate_count"] == 1

    async def test_marks_an_episode_the_model_was_not_offered(self, capfire, client, fake_llm, library):
        # The failure this catches is invisible from outside: the response is a
        # perfectly ordinary 200 saying she was not understood.
        fake_llm.respond_with({"action": "play_episode", "episode_id": 999, "spoken_response": "Playing it."})
        response = await client.post("/command", json={"transcript": TRANSCRIPT})

        assert response.status_code == 200
        attributes = command_span(capfire)["attributes"]
        assert attributes["failure"] == "episode_not_offered"
        # Both are needed to count overrides: the model asked to play, we did not.
        assert attributes["model_action"] == "play_episode"
        assert attributes["action"] == "unknown"

    async def test_records_the_shape_of_the_library_and_the_answer(self, capfire, client, fake_llm, library):
        fake_llm.respond_with({"action": "play_episode", "episode_id": 1, "spoken_response": "Playing."})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        attributes = command_span(capfire)["attributes"]
        assert attributes["feed_title"] == "The History Hour"
        assert attributes["feed_count"] == 1
        # Four words. A one- or two-word transcript is the truncation signal.
        assert attributes["transcript_words"] == len(TRANSCRIPT.split())
        # Published 2026-08-04, so comfortably inside the recency window rather
        # than something the back-catalogue search had to reach for.
        assert attributes["episode_age_days"] >= 0

    async def test_a_command_that_never_reached_an_outcome_still_says_so(self, capfire, client, fake_llm, library):
        # `action` is seeded to "error" rather than left absent: an outage must
        # be countable in the same group-by as everything else, not a silent
        # gap in it.
        fake_llm.fail_with(LLMError("provider is down"))
        response = await client.post("/command", json={"transcript": TRANSCRIPT})

        assert response.status_code == 503
        assert command_span(capfire)["attributes"]["action"] == "error"

    async def test_marks_a_decision_the_model_mangled(self, capfire, client, fake_llm, library):
        fake_llm.respond_with({"action": "play_episode", "episode_id": "not an integer"})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        assert command_span(capfire)["attributes"]["failure"] == "invalid_decision"


class TestWhatTheModelCost:
    """Token counts and latency, summed over a request rather than per call.

    Which model to run is decided on cost and reliability together, and until
    now both came from measuring by hand. Summing matters because a spoken
    request is not always one call: naming a show asks twice.
    """

    async def test_the_provider_reported_usage_reaches_the_span(self, capfire, respx_mock):
        # Through the real client, so this breaks if a provider stops sending
        # `usage` or renames its fields — which is the only way this silently
        # becomes zero.
        respx_mock.post(f"{BASE_URL}/chat/completions").respond(
            json={
                "choices": [{"message": {"content": '{"action": "unknown", "spoken_response": "Sorry?"}'}}],
                "usage": {"prompt_tokens": 3500, "completion_tokens": 45},
            }
        )
        model = OpenAICompatibleClient(base_url=BASE_URL, api_key="k", model="test-model")
        with logfire.span("command"), telemetry.collect_llm_usage():
            await model.decide(system="s", user="u", output_model=ModelDecision)

        attributes = command_span(capfire)["attributes"]
        assert attributes["llm_calls"] == 1
        assert attributes["llm_input_tokens"] == 3500
        assert attributes["llm_output_tokens"] == 45
        assert attributes["llm_seconds"] >= 0

    def test_calls_accumulate_rather_than_overwrite(self):
        # The play_from_show shape: work out the show, then pick within it.
        with telemetry.collect_llm_usage():
            telemetry.record_llm_call(input_tokens=3000, output_tokens=40, seconds=0.5)
            telemetry.record_llm_call(input_tokens=1200, output_tokens=20, seconds=0.3)
            usage = telemetry._llm_usage.get()

        assert usage is not None
        assert (usage.calls, usage.input_tokens, usage.output_tokens) == (2, 4200, 60)
        assert usage.seconds == pytest.approx(0.8)

    def test_recording_outside_a_request_is_harmless(self):
        # The poller and the eval runner both call models with no span open.
        telemetry.record_llm_call(input_tokens=10, output_tokens=1, seconds=0.1)


class TestPrivacy:
    """What leaves the server is what the published policy says leaves it.

    The transcript is sent deliberately, and disclosed. Everything these guard
    against is the opposite case — data leaving because nobody said it should
    not. FastAPI instrumentation attaches every parsed endpoint argument to the
    request span unless told otherwise, and for `POST /command` those arguments
    are the transcript *and* the `User` row, email included.
    """

    async def test_transcript_is_recorded(self, capfire, client, fake_llm, library):
        # Disclosed under "Keeping the app working" in static/privacy.html, and
        # the reason any of this can answer a question about accuracy.
        assert settings.telemetry_transcripts is True
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Sorry?"})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        assert command_span(capfire)["attributes"]["transcript"] == TRANSCRIPT

    async def test_transcript_is_absent_when_turned_off(self, capfire, client, fake_llm, library, monkeypatch):
        # Not just missing from our own attribute — gone from the trace
        # entirely. If the request span were still carrying the parsed body,
        # turning the setting off would achieve nothing at all.
        monkeypatch.setattr(settings, "telemetry_transcripts", False)
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Sorry?"})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        assert TRANSCRIPT not in str(capfire.exporter.exported_spans_as_dict())

    async def test_email_address_is_never_sent(self, capfire, client, fake_llm, library, user):
        # Her email is disclosed to nobody. It has no diagnostic use, and the
        # policy says the record is labelled by account identifier alone.
        user.email = "her@example.com"
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Sorry?"})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        assert "her@example.com" not in str(capfire.exporter.exported_spans_as_dict())

    async def test_telemetry_uses_only_the_severable_identifier(self, capfire, client, fake_llm, library, user):
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Sorry?"})
        await client.post("/command", json={"transcript": TRANSCRIPT})

        attributes = command_span(capfire)["attributes"]
        assert attributes["telemetry_id"] == str(user.telemetry_id)
        assert "user_id" not in attributes
        assert str(user.id) not in str(capfire.exporter.exported_spans_as_dict())

    def test_client_ip_is_scrubbed(self):
        """The ASGI instrumentation records the caller's IP; we throw it away.

        Asserted against the real configuration rather than an exported span,
        because the `capfire` fixture reconfigures Logfire with its own
        scrubbing and would report a pass whatever this file said.
        """
        from logfire._internal.config import GLOBAL_CONFIG

        telemetry.configure(service_name="test")
        scrubbing = GLOBAL_CONFIG.scrubbing
        # `False` here would mean scrubbing was switched off altogether, which
        # would also take the default password and token patterns with it.
        assert scrubbing is not False
        assert "peer.ip" in (scrubbing.extra_patterns or ())
