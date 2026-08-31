import json

import httpx
import pytest

from audioreader.commands.intents import ModelDecision
from audioreader.llm.client import LLMError
from audioreader.llm.openai_responses import (
    OpenAIResponsesClient,
    ResponseCompleted,
    ResponseTextDelta,
)

ENDPOINT = "https://api.openai.test/v1/responses"


@pytest.fixture
def client() -> OpenAIResponsesClient:
    return OpenAIResponsesClient(api_key="test-key", model="gpt-5.6-luna", url=ENDPOINT)


class TestDecide:
    async def test_uses_responses_structured_output(self, client, respx_mock):
        route = respx_mock.post(ENDPOINT).respond(
            json={
                "output": [
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": json.dumps(
                                    {
                                        "action": "unknown",
                                        "episode_id": None,
                                        "search_query": None,
                                        "episode_query": None,
                                        "speed": None,
                                        "spoken_response": "Which show?",
                                    }
                                ),
                            }
                        ],
                    }
                ],
                "usage": {"input_tokens": 10, "output_tokens": 5},
            }
        )

        result = await client.decide(system="SYSTEM", user="USER", output_model=ModelDecision)

        assert result["spoken_response"] == "Which show?"
        body = json.loads(route.calls.last.request.content)
        assert body["model"] == "gpt-5.6-luna"
        assert body["instructions"] == "SYSTEM"
        assert body["input"] == "USER"
        assert body["store"] is False
        assert body["text"]["format"]["type"] == "json_schema"
        assert body["text"]["format"]["strict"] is True

    async def test_http_failure_is_an_llm_error(self, client, respx_mock):
        respx_mock.post(ENDPOINT).mock(side_effect=httpx.ConnectError("offline"))
        with pytest.raises(LLMError):
            await client.decide(system="s", user="u", output_model=ModelDecision)


class TestStream:
    async def test_yields_text_and_completed_response(self, client, respx_mock):
        completed = {
            "id": "resp_1",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hello"}]}],
            "usage": {"input_tokens": 3, "output_tokens": 1},
        }
        stream = "\n".join(
            [
                "event: response.output_text.delta",
                'data: {"type":"response.output_text.delta","delta":"Hel"}',
                "",
                "event: response.output_text.delta",
                'data: {"type":"response.output_text.delta","delta":"lo"}',
                "",
                "event: response.completed",
                f"data: {json.dumps({'type': 'response.completed', 'response': completed})}",
                "",
                "data: [DONE]",
            ]
        )
        respx_mock.post(ENDPOINT).respond(text=stream, headers={"content-type": "text/event-stream"})

        events = [
            event
            async for event in client.stream(
                instructions="s", input_items=[{"role": "user", "content": "u"}], tools=[]
            )
        ]

        assert [event.text for event in events if isinstance(event, ResponseTextDelta)] == ["Hel", "lo"]
        assert [event.response["id"] for event in events if isinstance(event, ResponseCompleted)] == ["resp_1"]
