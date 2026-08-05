import pytest

from audioreader.llm.anthropic_client import AnthropicClient
from audioreader.llm.client import LLMClient
from audioreader.llm.openai_compatible import OpenAICompatibleClient
from audioreader.llm.provider import build_llm_client
from audioreader.settings_types import LLMProvider


class TestBuildLLMClient:
    def test_anthropic_provider(self, monkeypatch):
        from audioreader.config import settings

        monkeypatch.setattr(settings, "llm_provider", LLMProvider.ANTHROPIC)
        monkeypatch.setattr(settings, "anthropic_api_key", "sk-test")
        assert isinstance(build_llm_client(), AnthropicClient)

    def test_openrouter_provider(self, monkeypatch):
        from audioreader.config import settings

        monkeypatch.setattr(settings, "llm_provider", LLMProvider.OPENROUTER)
        monkeypatch.setattr(settings, "openrouter_api_key", "sk-or-test")
        client = build_llm_client()
        assert isinstance(client, OpenAICompatibleClient)
        assert client.model == settings.openrouter_model

    def test_missing_key_fails_loudly(self, monkeypatch):
        # Better to fail at startup than to serve 503s to a blind user.
        from audioreader.config import settings

        monkeypatch.setattr(settings, "llm_provider", LLMProvider.OPENROUTER)
        monkeypatch.setattr(settings, "openrouter_api_key", "")
        with pytest.raises(RuntimeError, match="OPENROUTER_API_KEY"):
            build_llm_client()


class TestProtocolConformance:
    @pytest.mark.parametrize("client_class", [AnthropicClient, OpenAICompatibleClient])
    def test_satisfies_llm_client_protocol(self, client_class):
        assert issubclass(client_class, LLMClient)
