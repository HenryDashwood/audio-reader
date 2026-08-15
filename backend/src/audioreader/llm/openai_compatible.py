"""LLMClient for any provider speaking the OpenAI chat-completions format.

That covers OpenAI, OpenRouter, DeepSeek's own API, Together, Groq, and a
locally-hosted vLLM — they differ only in base URL, key, and model name. Written
against httpx rather than a vendor SDK so switching provider stays a config
change rather than a code change.
"""

import json
from typing import Any

import httpx
from pydantic import BaseModel

from audioreader.llm.client import LLMError


def strict_json_schema(model: type[BaseModel]) -> dict[str, Any]:
    """Pydantic's JSON schema, adjusted for OpenAI-style strict mode.

    Strict mode demands that every property is listed in `required` and that
    objects forbid extra keys. Pydantic omits defaulted fields from `required`,
    so we add them back; nullability is already expressed as an anyOf branch.
    """
    schema = model.model_json_schema()
    _make_strict(schema)
    for definition in schema.get("$defs", {}).values():
        _make_strict(definition)
    return schema


def _make_strict(node: dict[str, Any]) -> None:
    if "properties" not in node:
        return
    node["required"] = list(node["properties"])
    node["additionalProperties"] = False


class OpenAICompatibleClient:
    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        app_title: str = "audioreader",
        timeout: float = 30.0,
        extra_payload: dict[str, Any] | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.model = model
        # Provider-specific request fields, e.g. OpenRouter's `reasoning`.
        self.extra_payload = extra_payload or {}
        self._headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            # OpenRouter uses these for attribution; harmless elsewhere.
            "X-Title": app_title,
        }
        self._timeout = timeout

    async def decide(self, *, system: str, user: str, output_model: type[BaseModel]) -> dict[str, Any]:
        # Extras go first so they can never overwrite the schema or messages.
        payload: dict[str, Any] = {
            **self.extra_payload,
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": output_model.__name__,
                    "strict": True,
                    "schema": strict_json_schema(output_model),
                },
            },
        }

        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(f"{self.base_url}/chat/completions", headers=self._headers, json=payload)
                response.raise_for_status()
                body = response.json()
        except httpx.HTTPError as exc:
            raise LLMError(f"{type(exc).__name__}: {exc}") from exc

        return _extract_json(body)


def _extract_json(body: dict[str, Any]) -> dict[str, Any]:
    # Gateways can return HTTP 200 with an error body when an upstream provider
    # fails, so a successful status code is not enough to trust the payload.
    if error := body.get("error"):
        raise LLMError(str(error.get("message", error)))

    choices = body.get("choices") or []
    if not choices:
        raise LLMError("provider returned no choices")

    content = choices[0].get("message", {}).get("content")
    if not content:
        raise LLMError("provider returned empty content")

    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        raise LLMError(f"provider returned non-JSON content: {content[:200]!r}") from exc

    if not isinstance(parsed, dict):
        raise LLMError(f"expected a JSON object, got {type(parsed).__name__}")
    return parsed
