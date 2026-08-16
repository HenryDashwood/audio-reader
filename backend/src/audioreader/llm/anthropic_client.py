import time

import anthropic
from pydantic import BaseModel

from audioreader import telemetry
from audioreader.config import settings
from audioreader.llm.client import LLMError


class AnthropicClient:
    """LLMClient backed by the Anthropic Messages API.

    Uses structured outputs, so the model is constrained to our schema rather
    than asked nicely to emit JSON.
    """

    def __init__(self, model: str | None = None, api_key: str | None = None):
        self.model = model or settings.llm_model
        self._client = anthropic.AsyncAnthropic(api_key=api_key or settings.anthropic_api_key)

    async def decide(self, *, system: str, user: str, output_model: type[BaseModel]) -> dict:
        started = time.perf_counter()
        try:
            response = await self._client.messages.parse(
                model=self.model,
                max_tokens=1024,
                system=system,
                messages=[{"role": "user", "content": user}],
                output_format=output_model,
            )
        except anthropic.APIError as exc:
            raise LLMError(f"{type(exc).__name__}: {exc}") from exc

        telemetry.record_llm_call(
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            seconds=time.perf_counter() - started,
        )

        parsed = response.parsed_output
        if parsed is None:
            raise LLMError("model returned no parsable output")
        return parsed.model_dump()
