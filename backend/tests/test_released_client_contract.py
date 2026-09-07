"""Exercise the requests made by v1.4.1 and optionally export real responses.

The macOS compatibility gate replays these exchanges through the *unchanged*
released Swift client. These cases also run in the ordinary backend gate.
Never regenerate the frozen client just to make a backend change pass.
"""

import hashlib
import json
import os
from datetime import UTC, datetime
from pathlib import Path

from httpx import ASGITransport, AsyncClient

from audioreader.auth.dependencies import get_current_user
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.llm.client import LLMError
from audioreader.llm.openai_responses import ResponseCompleted, ResponseTextDelta
from audioreader.llm.provider import get_conversation_llm_client
from audioreader.main import create_app
from audioreader.models import Episode, Feed, Subscription
from audioreader.schemas import CommandRequest

ROOT = Path(__file__).resolve().parents[2]


def test_release_sources_match_the_recorded_baseline():
    baseline = ROOT / "compatibility" / "ios-v1.4.1"
    manifest = json.loads((baseline / "manifest.json").read_text())
    for name, digest in manifest["sha256"].items():
        assert hashlib.sha256((baseline / name).read_bytes()).hexdigest() == digest, name


def test_clients_without_capabilities_keep_single_action_behaviour():
    assert CommandRequest(transcript="play something").supports_compound_actions is False


async def test_released_client_exchanges(client, session, user, fake_llm, monkeypatch):
    monkeypatch.setattr(settings, "command_rate_limit_per_minute", 0)
    monkeypatch.setattr(settings, "inbound_email_domain", "inbox.example.com")
    monkeypatch.setattr(settings, "inbound_email_secret", "test-only")
    feed = Feed(id=101, url="https://example.com/feed.xml", title="Compatibility library")
    episode = Episode(
        id=201,
        feed=feed,
        guid="compatibility-podcast",
        title="The Congress of Vienna",
        audio_url="https://cdn.example.com/201.mp3",
        duration_seconds=2700,
        published_at=datetime(2026, 9, 1, 12, 0, 0, 123456, tzinfo=UTC),
    )
    article = Episode(
        id=202,
        feed=feed,
        guid="compatibility-article",
        title="A written article",
        description="An article available offline.",
        article_text="An article available offline.",
        published_at=datetime(2026, 9, 1, tzinfo=UTC),
    )
    session.add_all([feed, episode, article, Subscription(user_id=user.id, feed=feed)])
    await session.commit()
    exchanges: list[dict[str, object]] = []

    async def exchange(name, method, path, body=None, status=200):
        response = await client.request(method, path, **({"json": body} if body is not None else {}))
        assert response.status_code == status, (name, response.text)
        exchanges.append(
            {
                "name": name,
                "method": method,
                "path": path,
                "request": body,
                "status": status,
                "response": response.text,
            }
        )
        return response.json() if response.content else None

    await exchange("me", "GET", "/me")
    await exchange("feeds", "GET", "/feeds")
    await exchange("episodes", "GET", "/feeds/101/episodes")
    await exchange("recent", "GET", "/episodes?limit=30")
    await exchange("episode", "GET", "/episodes/201")
    await exchange("text", "GET", "/episodes/202/text")
    await exchange("search", "GET", "/search/episodes?q=Vienna")
    await exchange(
        "position",
        "PUT",
        "/episodes/201/position",
        {
            "position_seconds": 45.5,
            "completed": False,
            "duration_seconds": 2700,
        },
        status=204,
    )
    saved = await exchange("savedPosition", "GET", "/episodes/201")
    assert saved["position_seconds"] == 45.5
    await exchange("dismiss", "PUT", "/episodes/201/state", {"dismissed": True}, status=204)
    dismissed = await exchange("dismissed", "GET", "/episodes/201")
    assert dismissed["dismissed"] is True
    await exchange("restore", "PUT", "/episodes/201/state", {"played": False, "dismissed": False}, status=204)
    fake_llm.respond_with({"action": "play_episode", "episode_id": 201, "spoken_response": "Playing Vienna."})
    play = await exchange("command", "POST", "/command", {"transcript": "play Vienna", "turns": []})
    assert play["action"] == "play_episode" and play["episode"]["id"] == 201
    assert not play.get("actions")
    fake_llm.respond_with({"action": "set_speed", "speed": 1.5, "spoken_response": "Speed changed."})
    speed = await exchange("speed", "POST", "/command", {"transcript": "speed up", "turns": []})
    assert speed["speed"] == 1.5
    fake_llm.fail_with(LLMError("test outage"))
    await exchange("speakableError", "POST", "/command", {"transcript": "play something", "turns": []}, status=503)
    await exchange("newsletterAddress", "GET", "/newsletters/address")
    await exchange("pendingNewsletters", "GET", "/newsletters/pending")
    await exchange("consent", "PUT", "/me/ai-data-sharing", {"granted": True})
    await exchange("clearLatest", "DELETE", "/episodes", status=204)
    await exchange("unsubscribe", "DELETE", "/feeds/101", status=204)

    class StreamedQuestion:
        async def stream(self, **kwargs):
            yield ResponseTextDelta("Which show would you like?")
            yield ResponseCompleted(
                {
                    "output": [
                        {"type": "message", "content": [{"type": "output_text", "text": "Which show would you like?"}]}
                    ]
                }
            )

    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[get_current_user] = lambda: user
    app.dependency_overrides[get_conversation_llm_client] = StreamedQuestion
    body = {"transcript": "which show", "turns": []}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as streaming:
        response = await streaming.post("/command/stream", json=body)
    assert response.status_code == 200
    envelopes = [json.loads(line) for line in response.text.splitlines() if line]
    results = [item["response"] for item in envelopes if item["type"] == "result"]
    assert len(results) == 1 and results[0]["expects_reply"] is True
    assert not results[0].get("actions")
    exchanges.append(
        {
            "name": "stream",
            "method": "POST",
            "path": "/command/stream",
            "request": body,
            "status": 200,
            "response": response.text,
        }
    )

    if output := os.environ.get("MAGPIE_CONTRACT_OUTPUT"):
        Path(output).write_text(json.dumps(exchanges, indent=2) + "\n")
