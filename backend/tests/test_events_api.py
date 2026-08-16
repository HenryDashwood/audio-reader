"""The client half of the wide event.

What is being protected here is the part of a spoken request the backend
otherwise cannot see. An attempt that dies on the phone makes no request at
all, so its whole existence depends on this endpoint accepting it.
"""

import pytest

from audioreader.routers import events


@pytest.fixture(autouse=True)
def clear_limits():
    events._limit._hits.clear()
    yield
    events._limit._hits.clear()


class TestVoiceAttempts:
    async def test_records_an_attempt_that_never_reached_the_backend(self, client):
        # The failure that took a night to find: she spoke, the microphone was
        # not live, and no command was ever sent. Until this existed, the only
        # trace of it was a POST that was missing.
        response = await client.post(
            "/events/voice",
            json={
                "outcome": "no_speech",
                "command_sent": False,
                "recogniser": "analyzer",
                "audio_first_buffer_ms": None,
                "listen_seconds": 8.0,
                "transcript_empty": True,
                "first_since_launch": True,
            },
        )
        assert response.status_code == 204

    async def test_records_a_command_that_worked(self, client):
        response = await client.post(
            "/events/voice",
            json={
                "outcome": "played",
                "command_sent": True,
                "recogniser": "analyzer",
                "audio_first_buffer_ms": 180,
                "listen_seconds": 3.2,
                "settled_at_end": True,
                "total_seconds": 4.9,
            },
        )
        assert response.status_code == 204

    async def test_records_a_command_resolved_on_the_phone(self, client):
        # Transport words never reach the server, so without this the busiest
        # thing she says is entirely absent from the record.
        response = await client.post(
            "/events/voice",
            json={"outcome": "transport", "transport_command": "pause"},
        )
        assert response.status_code == 204

    async def test_outcome_is_required(self, client):
        # Everything else is optional because an attempt can end anywhere, but
        # an event that does not say how it ended is not worth a row.
        assert (await client.post("/events/voice", json={})).status_code == 422

    async def test_grouping_fields_stay_small_and_tidy(self, client):
        # These are the columns worth grouping by, which stops working the
        # moment something free-form lands in one.
        response = await client.post(
            "/events/voice",
            json={"outcome": "  played  ", "error": "x" * 500},
        )
        assert response.status_code == 204

    async def test_a_blank_field_becomes_absent_rather_than_empty(self):
        from audioreader.schemas import VoiceAttemptEvent

        event = VoiceAttemptEvent(outcome="played", error="   ")
        assert event.error is None
        # Absent, not false or empty: the row should say only what the phone
        # actually knew.
        assert "error" not in event.model_dump(exclude_none=True)


class TestRateLimit:
    async def test_a_client_stuck_in_a_loop_cannot_flood_us(self, client, monkeypatch):
        monkeypatch.setattr(events._limit, "limit", 2)
        for _ in range(2):
            assert (await client.post("/events/voice", json={"outcome": "played"})).status_code == 204

        # Telemetry must never be the thing that takes the service down.
        response = await client.post("/events/voice", json={"outcome": "played"})
        assert response.status_code == 429
