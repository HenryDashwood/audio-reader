"""The seam between the app and whichever LLM provider we are using.

Everything above this line deals in plain dicts validated by our own Pydantic
models, so swapping providers is a matter of writing one new class.
"""

from typing import Any, Protocol, runtime_checkable

from pydantic import BaseModel


class LLMError(Exception):
    """The model could not be reached, or returned something unusable."""


@runtime_checkable
class LLMClient(Protocol):
    async def decide(
        self, *, system: str, user: str, output_model: type[BaseModel]
    ) -> dict[str, Any]:
        """Return the model's answer as a dict shaped like `output_model`.

        Implementations should raise LLMError for transport and provider
        failures. Callers must still validate the dict: a schema-constrained
        response can be well-formed and semantically wrong.
        """
        ...
