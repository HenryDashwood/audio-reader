from pathlib import Path

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from audioreader.settings_types import LLMProvider

# backend/src/audioreader/config.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


def redacted_database_url(url: str) -> str:
    """The URL with its password removed, safe to log.

    Worth logging at startup: the host alone tells you whether a deployment
    picked up the platform's database or silently fell back to the local
    default, which is otherwise only visible as a connection-refused stack
    trace several seconds later.
    """
    scheme, separator, rest = url.partition("://")
    if not separator or "@" not in rest:
        return url
    credentials, _, host = rest.rpartition("@")
    user, _, _password = credentials.partition(":")
    return f"{scheme}://{user}:***@{host}"


def normalise_database_url(url: str) -> str:
    """Give Postgres URLs the async driver SQLAlchemy needs.

    Hosting providers hand out `postgresql://` (or the older `postgres://`),
    which the async engine rejects. Rewriting here means the deployment can
    just point AUDIOREADER_DATABASE_URL at whatever the platform provides.
    """
    for prefix in ("postgresql://", "postgres://"):
        if url.startswith(prefix):
            return "postgresql+asyncpg://" + url[len(prefix) :]
    return url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        # Anchored to the repo, so settings load the same whether you run from
        # the root, from backend/, or from an installed package.
        env_file=(REPO_ROOT / ".env", REPO_ROOT / "backend" / ".env"),
        env_prefix="AUDIOREADER_",
        extra="ignore",
    )

    # Also accept the platform's own DATABASE_URL, which is what Railway,
    # Fly and Heroku all inject automatically.
    database_url: str = Field(
        default="postgresql+asyncpg://audioreader:audioreader@localhost:5432/audioreader",
        validation_alias=AliasChoices("AUDIOREADER_DATABASE_URL", "DATABASE_URL"),
    )

    @field_validator("database_url")
    @classmethod
    def _with_async_driver(cls, value: str) -> str:
        return normalise_database_url(value)

    poll_interval_seconds: int = 900  # 0 disables the background poller

    # Consecutive failed polls before a feed is treated as broken rather than
    # briefly unreachable. At the default interval that is a bit over an hour,
    # which comfortably outlasts an ordinary blip.
    feed_failure_threshold: int = 5

    # How long an unsubscribed, never-listened-to feed stays in the shared
    # catalog before being cleaned up. Generous: re-subscribing to a feed that
    # is still there is instant, and the only cost of keeping it is disk.
    orphan_feed_retention_days: int = 30
    # Capped per pass so a first cleanup of a long-neglected database is a
    # series of small deletes rather than one long table lock.
    orphan_prune_batch_size: int = 200

    # Sign in with Apple: identity tokens are verified against Apple's public
    # keys, with the app's bundle id as the required audience. No secret needed.
    apple_bundle_id: str = "com.henrydashwood.hearful"
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"

    # How long a session token stays good after its last use. Long, because
    # being signed out is a wall this user cannot climb unaided — but not
    # forever, so a lost or replaced phone stops being a live key eventually.
    # Every request refreshes the clock; 0 disables expiry.
    session_idle_timeout_days: int = 180

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

    # Finding a blog's feed from a spoken name is the one task worth being
    # slow and thorough at: it happens once per publication, and OpenRouter's
    # web plugin lets the model search for sites it does not know.
    discovery_web_search: bool = True
    discovery_timeout_seconds: float = 120.0

    # What one account may spend on spoken commands. The per-minute figure is
    # a burst guard — no human asks for a podcast twelve times a minute — and
    # the daily one is the actual budget, since a client stuck in a polite
    # retry loop could otherwise sit just under the burst limit indefinitely.
    # Set either to 0 to disable that window.
    command_rate_limit_per_minute: int = 12
    command_rate_limit_per_day: int = 500


settings = Settings()
