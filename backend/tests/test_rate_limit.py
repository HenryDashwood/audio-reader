"""The budget guard on /command, which is the only expensive endpoint."""

import pytest

from audioreader.ratelimit import SlidingWindow
from audioreader.routers import commands


class TestSlidingWindow:
    def test_allows_up_to_the_limit(self):
        window = SlidingWindow(limit=3, window_seconds=60)
        assert [window.check("mum", now=0).allowed for _ in range(3)] == [True, True, True]

    def test_rejects_beyond_the_limit(self):
        window = SlidingWindow(limit=2, window_seconds=60)
        window.check("mum", now=0)
        window.check("mum", now=0)
        assert window.check("mum", now=0).allowed is False

    def test_slot_frees_as_the_window_slides(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        assert window.check("mum", now=0).allowed
        assert not window.check("mum", now=59).allowed
        assert window.check("mum", now=61).allowed

    def test_keys_are_independent(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        assert window.check("mum", now=0).allowed
        # Henry hitting his own limit must not depend on hers.
        assert window.check("henry", now=0).allowed

    def test_rejected_hits_do_not_extend_the_wait(self):
        # Retrying while blocked must not push the reopening further out, or a
        # client that retries steadily could lock itself out indefinitely.
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("mum", now=0)
        for moment in (10, 20, 30, 40, 50):
            assert not window.check("mum", now=moment).allowed
        assert window.check("mum", now=61).allowed

    def test_retry_after_counts_down(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("mum", now=0)
        assert window.check("mum", now=0).retry_after == 61
        assert window.check("mum", now=50).retry_after == 11

    def test_retry_after_is_never_zero_when_blocked(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("mum", now=0)
        # Retry-After: 0 would invite an immediate retry that fails again.
        assert window.check("mum", now=59.999).retry_after >= 1

    def test_prune_forgets_idle_keys(self):
        window = SlidingWindow(limit=1, window_seconds=60)
        window.check("mum", now=0)
        window.prune(now=1000)
        assert window._hits == {}

    def test_prune_keeps_live_keys(self):
        window = SlidingWindow(limit=2, window_seconds=60)
        window.check("mum", now=0)
        window.prune(now=10)
        # Pruning must not hand back a slot that has not expired.
        assert window.check("mum", now=10).allowed
        assert not window.check("mum", now=10).allowed


@pytest.fixture
def tight_limits(monkeypatch):
    """Two commands a minute, so a test can reach the limit in three calls."""
    monkeypatch.setattr(commands, "_burst_limit", SlidingWindow(limit=2, window_seconds=60))
    monkeypatch.setattr(commands, "_daily_limit", SlidingWindow(limit=1000, window_seconds=86400))


class TestCommandEndpoint:
    async def test_over_the_limit_is_429(self, client, fake_llm, tight_limits):
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Which one?"})
        for _ in range(2):
            assert (await client.post("/command", json={"transcript": "hi"})).status_code == 200

        response = await client.post("/command", json={"transcript": "hi"})
        assert response.status_code == 429

    async def test_the_refusal_is_speakable(self, client, fake_llm, tight_limits):
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Which one?"})
        for _ in range(2):
            await client.post("/command", json={"transcript": "hi"})

        response = await client.post("/command", json={"transcript": "hi"})
        # She cannot read a status code; every refusal must have a sentence.
        assert response.json()["detail"]["spoken_response"]
        assert int(response.headers["Retry-After"]) > 0

    async def test_a_limit_of_zero_disables_the_window(self, client, fake_llm, monkeypatch):
        monkeypatch.setattr(commands, "_burst_limit", SlidingWindow(limit=0, window_seconds=60))
        monkeypatch.setattr(commands, "_daily_limit", SlidingWindow(limit=0, window_seconds=86400))
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Which one?"})
        for _ in range(20):
            assert (await client.post("/command", json={"transcript": "hi"})).status_code == 200

    async def test_the_daily_window_also_bites(self, client, fake_llm, monkeypatch):
        monkeypatch.setattr(commands, "_burst_limit", SlidingWindow(limit=1000, window_seconds=60))
        monkeypatch.setattr(commands, "_daily_limit", SlidingWindow(limit=2, window_seconds=86400))
        fake_llm.respond_with({"action": "unknown", "spoken_response": "Which one?"})
        for _ in range(2):
            await client.post("/command", json={"transcript": "hi"})

        response = await client.post("/command", json={"transcript": "hi"})
        assert response.status_code == 429
        assert "tomorrow" in response.json()["detail"]["spoken_response"]
