"""In-memory LLM stand-in so tests never touch the network."""

from typing import Any

from pydantic import BaseModel

from audioreader.llm.client import LLMError


class FakeLLMClient:
    def __init__(self, response: dict[str, Any] | None = None, error: Exception | None = None):
        self.response = response
        self.error = error
        self.calls: list[dict[str, Any]] = []

    def respond_with(self, response: dict[str, Any]) -> None:
        self.response = response
        self.error = None

    def fail_with(self, error: Exception) -> None:
        self.error = error

    async def decide(
        self, *, system: str, user: str, output_model: type[BaseModel]
    ) -> dict[str, Any]:
        self.calls.append({"system": system, "user": user, "output_model": output_model})
        if self.error is not None:
            raise self.error
        if self.response is None:
            raise LLMError("FakeLLMClient has no configured response")
        return self.response
