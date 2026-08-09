from functools import lru_cache

from audioreader.config import settings
from audioreader.llm.anthropic_client import AnthropicClient
from audioreader.llm.client import LLMClient
from audioreader.llm.openai_compatible import OpenAICompatibleClient
from audioreader.settings_types import LLMProvider


def build_llm_client() -> LLMClient:
    """Construct the configured provider's client.

    A missing key raises here rather than at request time: better to fail on
    deploy than to hand the listener a 503 the first time she asks for
    something.
    """
    match settings.llm_provider:
        case LLMProvider.ANTHROPIC:
            if not settings.anthropic_api_key:
                raise RuntimeError("ANTHROPIC_API_KEY is not set")
            return AnthropicClient()
        case LLMProvider.OPENROUTER:
            if not settings.openrouter_api_key:
                raise RuntimeError("OPENROUTER_API_KEY is not set")
            return OpenAICompatibleClient(
                base_url=settings.openrouter_base_url,
                api_key=settings.openrouter_api_key,
                model=settings.openrouter_model,
                extra_payload={"reasoning": {"enabled": settings.openrouter_reasoning}},
            )


def build_discovery_llm_client() -> LLMClient:
    """The client for finding a publication's feed from its spoken name.

    Same provider as the main client, but tuned for thoroughness over speed:
    reasoning on, a long timeout, and (on OpenRouter) the web plugin so the
    model can search for sites it does not already know. This path runs once
    per new publication, so the extra cost and latency are well spent.
    """
    match settings.llm_provider:
        case LLMProvider.ANTHROPIC:
            if not settings.anthropic_api_key:
                raise RuntimeError("ANTHROPIC_API_KEY is not set")
            return AnthropicClient()
        case LLMProvider.OPENROUTER:
            if not settings.openrouter_api_key:
                raise RuntimeError("OPENROUTER_API_KEY is not set")
            extra: dict = {"reasoning": {"enabled": True}}
            if settings.discovery_web_search:
                extra["plugins"] = [{"id": "web"}]
            return OpenAICompatibleClient(
                base_url=settings.openrouter_base_url,
                api_key=settings.openrouter_api_key,
                model=settings.openrouter_model,
                timeout=settings.discovery_timeout_seconds,
                extra_payload=extra,
            )


@lru_cache(maxsize=1)
def _cached_client() -> LLMClient:
    return build_llm_client()


def get_llm_client() -> LLMClient:
    """FastAPI dependency; overridden with a fake in tests."""
    return _cached_client()


@lru_cache(maxsize=1)
def _cached_discovery_client() -> LLMClient:
    return build_discovery_llm_client()


def get_discovery_llm_client() -> LLMClient:
    """FastAPI dependency; overridden with a fake in tests."""
    return _cached_discovery_client()
