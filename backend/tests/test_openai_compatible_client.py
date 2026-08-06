import json

import httpx
import pytest

from audioreader.commands.intents import ModelDecision
from audioreader.llm.client import LLMError
from audioreader.llm.openai_compatible import OpenAICompatibleClient, strict_json_schema

BASE_URL = "https://openrouter.test/api/v1"
ENDPOINT = f"{BASE_URL}/chat/completions"


@pytest.fixture
def client() -> OpenAICompatibleClient:
    return OpenAICompatibleClient(
        base_url=BASE_URL,
        api_key="test-key",
        model="deepseek/deepseek-v4-flash-0731",
        app_title="audioreader-test",
    )


def completion(content: dict | str) -> dict:
    text = content if isinstance(content, str) else json.dumps(content)
    return {"choices": [{"message": {"role": "assistant", "content": text}}]}


class TestStrictSchema:
    def test_every_property_is_required(self):
        # Strict mode rejects schemas where an optional field is absent from
        # `required`, but Pydantic omits defaulted fields — so we add them back.
        schema = strict_json_schema(ModelDecision)
        assert set(schema["required"]) == set(schema["properties"])

    def test_additional_properties_disallowed(self):
        assert strict_json_schema(ModelDecision)["additionalProperties"] is False

    def test_nested_definitions_are_also_strict(self):
        # $defs carries the Action enum; every object in the tree must comply.
        for definition in strict_json_schema(ModelDecision).get("$defs", {}).values():
            if definition.get("type") == "object":
                assert definition["additionalProperties"] is False


class TestDecide:
    async def test_returns_parsed_content(self, client, respx_mock):
        respx_mock.post(ENDPOINT).respond(
            json=completion({"action": "play_episode", "episode_id": 7, "spoken_response": "ok"})
        )
        result = await client.decide(system="s", user="u", output_model=ModelDecision)
        assert result == {"action": "play_episode", "episode_id": 7, "spoken_response": "ok"}

    async def test_sends_model_prompt_and_schema(self, client, respx_mock):
        route = respx_mock.post(ENDPOINT).respond(
            json=completion({"action": "unknown", "episode_id": None, "spoken_response": "?"})
        )
        await client.decide(system="SYSTEM", user="USER", output_model=ModelDecision)

        body = json.loads(route.calls.last.request.content)
        assert body["model"] == "deepseek/deepseek-v4-flash-0731"
        assert body["messages"] == [
            {"role": "system", "content": "SYSTEM"},
            {"role": "user", "content": "USER"},
        ]
        assert body["response_format"]["type"] == "json_schema"
        assert body["response_format"]["json_schema"]["strict"] is True

    async def test_sends_extra_payload(self, respx_mock):
        # Provider-specific knobs (e.g. OpenRouter's `reasoning`) must reach
        # the request without every caller knowing about them.
        client = OpenAICompatibleClient(
            base_url=BASE_URL,
            api_key="k",
            model="m",
            extra_payload={"reasoning": {"enabled": False}},
        )
        route = respx_mock.post(ENDPOINT).respond(
            json=completion({"action": "unknown", "episode_id": None, "spoken_response": "?"})
        )
        await client.decide(system="s", user="u", output_model=ModelDecision)

        body = json.loads(route.calls.last.request.content)
        assert body["reasoning"] == {"enabled": False}

    async def test_extra_payload_cannot_clobber_the_schema(self, respx_mock):
        client = OpenAICompatibleClient(
            base_url=BASE_URL, api_key="k", model="m", extra_payload={"response_format": "nonsense"}
        )
        route = respx_mock.post(ENDPOINT).respond(
            json=completion({"action": "unknown", "episode_id": None, "spoken_response": "?"})
        )
        await client.decide(system="s", user="u", output_model=ModelDecision)

        body = json.loads(route.calls.last.request.content)
        assert body["response_format"]["type"] == "json_schema"

    async def test_sends_auth_header(self, client, respx_mock):
        route = respx_mock.post(ENDPOINT).respond(
            json=completion({"action": "unknown", "episode_id": None, "spoken_response": "?"})
        )
        await client.decide(system="s", user="u", output_model=ModelDecision)
        assert route.calls.last.request.headers["authorization"] == "Bearer test-key"

    async def test_http_error_becomes_llm_error(self, client, respx_mock):
        respx_mock.post(ENDPOINT).respond(status_code=502, text="bad gateway")
        with pytest.raises(LLMError):
            await client.decide(system="s", user="u", output_model=ModelDecision)

    async def test_transport_error_becomes_llm_error(self, client, respx_mock):
        respx_mock.post(ENDPOINT).mock(side_effect=httpx.ConnectError("no route"))
        with pytest.raises(LLMError):
            await client.decide(system="s", user="u", output_model=ModelDecision)

    async def test_non_json_content_becomes_llm_error(self, client, respx_mock):
        # A provider that ignores the schema must not crash the request path.
        respx_mock.post(ENDPOINT).respond(json=completion("I'm afraid I can't do that"))
        with pytest.raises(LLMError):
            await client.decide(system="s", user="u", output_model=ModelDecision)

    async def test_empty_choices_becomes_llm_error(self, client, respx_mock):
        respx_mock.post(ENDPOINT).respond(json={"choices": []})
        with pytest.raises(LLMError):
            await client.decide(system="s", user="u", output_model=ModelDecision)

    async def test_provider_error_payload_becomes_llm_error(self, client, respx_mock):
        # OpenRouter returns 200 with an error body when an upstream fails.
        respx_mock.post(ENDPOINT).respond(
            json={"error": {"message": "upstream model unavailable", "code": 502}}
        )
        with pytest.raises(LLMError, match="upstream model unavailable"):
            await client.decide(system="s", user="u", output_model=ModelDecision)
