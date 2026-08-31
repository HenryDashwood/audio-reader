"""Direct client for OpenAI's Responses API.

The ordinary ``decide`` method keeps the existing structured command path
working. ``stream`` is the richer seam used by the voice conversation: it
surfaces text as it is written and hands completed function calls back to the
tool loop.
"""

import json
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any, Protocol

import httpx
from pydantic import BaseModel

from audioreader import telemetry
from audioreader.llm.client import LLMError
from audioreader.llm.openai_compatible import strict_json_schema


@dataclass(frozen=True)
class ResponseTextDelta:
    text: str


@dataclass(frozen=True)
class ResponseCompleted:
    response: dict[str, Any]


ResponseEvent = ResponseTextDelta | ResponseCompleted


class ResponsesStreamingClient(Protocol):
    def stream(
        self,
        *,
        instructions: str,
        input_items: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[ResponseEvent]: ...


class OpenAIResponsesClient:
    def __init__(
        self,
        *,
        api_key: str,
        model: str,
        url: str = "https://api.openai.com/v1/responses",
        reasoning_effort: str = "low",
        timeout: float = 60.0,
        web_search: bool = False,
    ) -> None:
        self.model = model
        self.url = url
        self.reasoning_effort = reasoning_effort
        self.timeout = timeout
        self.web_search = web_search
        self._headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }

    def payload(
        self,
        *,
        instructions: str,
        input_items: str | list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        stream: bool = False,
        text: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.model,
            "instructions": instructions,
            "input": input_items,
            # The phone sends the few turns which still matter. Avoid keeping
            # a second, server-side copy of a listener's conversation.
            "store": False,
            "stream": stream,
            "reasoning": {"effort": self.reasoning_effort},
        }
        selected_tools = list(tools or [])
        if self.web_search and not any(tool.get("type") == "web_search" for tool in selected_tools):
            selected_tools.append({"type": "web_search"})
        if selected_tools:
            payload["tools"] = selected_tools
            payload["parallel_tool_calls"] = False
        if text is not None:
            payload["text"] = text
        return payload

    async def decide(self, *, system: str, user: str, output_model: type[BaseModel]) -> dict[str, Any]:
        payload = self.payload(
            instructions=system,
            input_items=user,
            text={
                "format": {
                    "type": "json_schema",
                    "name": output_model.__name__,
                    "strict": True,
                    "schema": strict_json_schema(output_model),
                }
            },
        )
        started = time.perf_counter()
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(self.url, headers=self._headers, json=payload)
                response.raise_for_status()
                body = response.json()
        except httpx.HTTPError as exc:
            raise LLMError(f"{type(exc).__name__}: {exc}") from exc

        self._record_usage(body, started)
        content = _output_text(body)
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError as exc:
            raise LLMError(f"OpenAI returned non-JSON content: {content[:200]!r}") from exc
        if not isinstance(parsed, dict):
            raise LLMError(f"expected a JSON object, got {type(parsed).__name__}")
        return parsed

    async def stream(
        self,
        *,
        instructions: str,
        input_items: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[ResponseEvent]:
        payload = self.payload(
            instructions=instructions,
            input_items=input_items,
            tools=tools,
            stream=True,
        )
        started = time.perf_counter()
        completed: dict[str, Any] | None = None
        try:
            timeout = httpx.Timeout(self.timeout, read=None)
            async with httpx.AsyncClient(timeout=timeout) as client:
                async with client.stream("POST", self.url, headers=self._headers, json=payload) as response:
                    response.raise_for_status()
                    async for line in response.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        raw = line.removeprefix("data:").strip()
                        if not raw or raw == "[DONE]":
                            continue
                        event = json.loads(raw)
                        match event.get("type"):
                            case "response.output_text.delta":
                                if delta := event.get("delta"):
                                    yield ResponseTextDelta(str(delta))
                            case "response.completed":
                                completed = event.get("response") or {}
                                yield ResponseCompleted(completed)
                            case "error" | "response.failed" | "response.incomplete":
                                detail = event.get("error") or event.get("response", {}).get("error") or event
                                raise LLMError(f"OpenAI response failed: {detail}")
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            raise LLMError(f"{type(exc).__name__}: {exc}") from exc
        finally:
            if completed is not None:
                self._record_usage(completed, started)

    @staticmethod
    def _record_usage(body: dict[str, Any], started: float) -> None:
        usage = body.get("usage") or {}
        telemetry.record_llm_call(
            input_tokens=usage.get("input_tokens") or 0,
            output_tokens=usage.get("output_tokens") or 0,
            seconds=time.perf_counter() - started,
        )


def _output_text(body: dict[str, Any]) -> str:
    if error := body.get("error"):
        raise LLMError(str(error.get("message", error)))
    parts = [
        content.get("text", "")
        for item in body.get("output") or []
        for content in item.get("content") or []
        if content.get("type") == "output_text"
    ]
    text = "".join(parts).strip()
    if not text:
        raise LLMError("OpenAI returned empty content")
    return text
