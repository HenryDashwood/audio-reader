from pathlib import Path

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from audioreader.settings_types import LLMProvider

# backend/src/audioreader/config.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        # Anchored to the repo, so settings load the same whether you run from
        # the root, from backend/, or from an installed package.
        env_file=(REPO_ROOT / ".env", REPO_ROOT / "backend" / ".env"),
        env_prefix="AUDIOREADER_",
        extra="ignore",
    )

    database_url: str = "postgresql+asyncpg://audioreader:audioreader@localhost:5432/audioreader"
    poll_interval_seconds: int = 900  # 0 disables the background poller

    # DeepSeek V4 Flash matched Opus 5 and Haiku 4.5 on every episode-selection
    # query we tried, at ~1/55 the cost of Opus. Switch back with
    # AUDIOREADER_LLM_PROVIDER=anthropic if harder queries need it.
    llm_provider: LLMProvider = LLMProvider.OPENROUTER

    # Also accept the bare vendor key names the SDKs and CLIs already use, so
    # there is one key name to manage rather than an audioreader-specific one.
    anthropic_api_key: str = Field(
        default="",
        validation_alias=AliasChoices("AUDIOREADER_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"),
    )
    llm_model: str = "claude-opus-5"

    openrouter_api_key: str = Field(
        default="",
        validation_alias=AliasChoices("AUDIOREADER_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"),
    )
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    openrouter_model: str = "deepseek/deepseek-v4-flash-0731"
    # DeepSeek V4 Flash reasons before answering by default, which cost 4-14s
    # per command and varied wildly. Picking an episode from a labelled list
    # does not need it: measured ~1.1s and no loss of accuracy without.
    openrouter_reasoning: bool = False
    # How many episodes the model gets to choose between. Every candidate costs
    # input tokens on each spoken command, so this is the main cost dial.
    command_candidate_limit: int = 60


settings = Settings()
