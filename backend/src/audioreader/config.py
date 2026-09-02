from pathlib import Path
from typing import Self

from pydantic import AliasChoices, Field, field_validator, model_validator
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

    # Which deployment this is, as telemetry labels it. Railway names its own
    # environments, so on a deploy this is "production" without anyone setting
    # it; on a laptop it stays "development" and the two never mix in a chart.
    environment: str = Field(
        default="development",
        validation_alias=AliasChoices("AUDIOREADER_ENVIRONMENT", "RAILWAY_ENVIRONMENT_NAME"),
    )

    # A fixed bearer token for local simulator and physical-device development.
    # Empty by default: the ordinary server still requires Sign in with Apple
    # unless the developer deliberately starts it with this setting. Production
    # rejects the setting outright rather than trusting deployment convention.
    development_auth_token: str = ""

    @model_validator(mode="after")
    def _development_auth_never_runs_in_production(self) -> Self:
        if self.development_auth_token and self.environment.casefold() != "development":
            raise ValueError("development_auth_token is allowed only in the development environment")
        return self

    @property
    def development_auth_enabled(self) -> bool:
        return self.environment.casefold() == "development" and bool(self.development_auth_token)

    # The Logfire write token. Read through settings rather than left to the
    # SDK's own lookup because that only reads the process environment, and on
    # a laptop this lives in `.env` like every other key here. Both spellings
    # are accepted: LOGFIRE_TOKEN is what Logfire's docs and CLI use, and
    # LOGFIRE_API_KEY is what the project's own .env has always called it.
    #
    # Blank is the ordinary case — tests, CI, a laptop with nothing to report —
    # and means telemetry is created and dropped rather than sent.
    logfire_token: str = Field(
        default="",
        validation_alias=AliasChoices("LOGFIRE_TOKEN", "LOGFIRE_API_KEY"),
    )

    # Whether the spoken text is attached to the telemetry for a command.
    #
    # On, because when a command does the wrong thing the transcript is the
    # whole of the evidence: everything else recorded says what happened, and
    # nothing says what was asked for. The privacy policy discloses this and
    # promises deletion after 30 days — so if this is turned off, or the
    # retention is changed, change the policy to match. The policy is the
    # promise; this setting is only how it is kept.
    telemetry_transcripts: bool = True

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

    # Newsletters arrive by email at <token>@<inbound_email_domain>. Blank
    # means the feature is off: no addresses are handed out and the inbound
    # endpoint refuses everything, so a deployment without mail set up is
    # simply an app without newsletters rather than one with a silent hole.
    inbound_email_domain: str = ""
    # Shared with the mail-receiving Worker, which signs each message it
    # forwards (HMAC-SHA256 over the raw bytes). Blank disables the endpoint
    # even when a domain is configured.
    inbound_email_secret: str = ""
    # Newsletters are text; a message bigger than this is not one. Cloudflare
    # itself stops at 25 MiB.
    inbound_email_max_bytes: int = 10 * 1024 * 1024
    # How long the raw bytes of a received email are kept for reprocessing
    # before being dropped. The episode made from it is kept regardless.
    inbound_raw_retention_days: int = 7
    # A sender she has neither approved nor blocked is forgotten, along with
    # its messages, once it has been quiet this long.
    newsletter_pending_retention_days: int = 30
    # After the app signs her up to a newsletter, mail from it within this
    # many days is recognised as the reply: its confirmation link is followed
    # and its first issue goes straight into Following.
    newsletter_signup_window_days: int = 7

    @property
    def inbound_email_enabled(self) -> bool:
        return bool(self.inbound_email_domain and self.inbound_email_secret)

    # Sign in with Apple: identity tokens are verified against Apple's public
    # keys, with the app's bundle id as the required audience. No secret needed.
    apple_bundle_id: str = "com.henrydashwood.hearful"
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"

    # Telling Apple when an account is deleted (guideline 5.1.1(v)) does need a
    # secret: a JWT signed with a Sign in with Apple private key. Leave any of
    # these blank and the revocation step is skipped — deletion still works,
    # it just goes unreported. That is the right failure mode: erasing her data
    # must never depend on Apple being reachable.
    apple_team_id: str = ""
    apple_key_id: str = ""
    apple_private_key: str = ""  # the .p8 file's contents
    apple_token_url: str = "https://appleid.apple.com/auth/token"
    apple_revoke_url: str = "https://appleid.apple.com/auth/revoke"

    @field_validator("apple_private_key")
    @classmethod
    def _with_real_newlines(cls, value: str) -> str:
        """Accept a key pasted with literal backslash-n.

        A .p8 is a multi-line PEM. Some hosting dashboards accept a real
        multi-line value and some mangle it, so both spellings are tolerated
        rather than failing at the first sign-in after a deploy.
        """
        return value.replace("\\n", "\n")

    @property
    def apple_revocation_configured(self) -> bool:
        return bool(self.apple_team_id and self.apple_key_id and self.apple_private_key)

    # Encrypts the Apple refresh tokens held for revocation, so a leaked
    # database dump alone does not hand them over. Blank means store them as
    # they are. Losing this key costs only the ability to tell Apple about
    # deletions — never the ability to delete.
    apple_token_encryption_key: str = ""

    # How long a session token stays good after its last use. Long, because
    # being signed out is a wall this user cannot climb unaided — but not
    # forever, so a lost or replaced phone stops being a live key eventually.
    # Every request refreshes the clock; 0 disables expiry.
    session_idle_timeout_days: int = 180

    # Direct OpenAI Responses is the default. It supports the streamed,
    # tool-using conversation used by voice control without routing a
    # listener's words through an additional provider.
    llm_provider: LLMProvider = LLMProvider.OPENAI

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
    # Chosen on `backend/evals`, not on impressions: GPT-5.6 Luna is the only
    # cheap model that has scored the whole corpus clean over three repeats,
    # where DeepSeek V4 Flash returned malformed JSON on a few percent of
    # calls and misrouted requests for shows she does not subscribe to.
    #
    # It is also the cheaper of the two here, which is not obvious from the
    # rate card — Luna's output tokens cost twice DeepSeek's. One spoken
    # command is about 3,500 input tokens against 45 output, so input price is
    # very nearly the only price that matters. Weigh a replacement the same
    # way, and run the corpus before switching.
    openrouter_model: str = "openai/gpt-5.6-luna"
    # Reasoning off. DeepSeek V4 Flash reasoned before answering by default,
    # which cost 4-14s per command and varied wildly; picking an episode from
    # a labelled list does not need it, and Luna answers in about a second
    # without. Kept as a setting because a harder model may want it back.
    openrouter_reasoning: bool = False
    # How many recent episodes the model gets to choose between. Every
    # candidate costs input tokens on each spoken command, so this is the main
    # cost dial.
    command_candidate_limit: int = 60
    # How many older episodes matching what she actually said are added to
    # that window. Feeds carry their whole archive — In Our Time is past a
    # thousand episodes, back to 1998 — so recency alone puts anything more
    # than a couple of months old permanently out of reach, however precisely
    # she names it. These only cost tokens when her words match something old.
    # Set to 0 to go back to a pure recency window.
    command_search_limit: int = 15

    # Direct OpenAI Responses interprets the text produced on the phone. The
    # standard key never leaves the backend.
    openai_api_key: str = Field(
        default="",
        validation_alias=AliasChoices("AUDIOREADER_OPENAI_API_KEY", "OPENAI_API_KEY"),
    )
    openai_responses_url: str = "https://api.openai.com/v1/responses"
    openai_model: str = "gpt-5.6-luna"
    # Luna can use the tools and infer likely names without emitting separate
    # reasoning tokens. Those tokens added roughly ten seconds to a simple
    # already-subscribed answer in real-device testing.
    openai_reasoning_effort: str = "none"

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
    # Telemetry is not allowed to be what takes the service down. One event
    # per spoken attempt is a handful a day; this is sized for a queue
    # draining after an outage, not for steady use. 0 disables the endpoint's
    # limit entirely.
    event_rate_limit_per_minute: int = 60
    # Fetching and parsing arbitrary publications is materially more expensive
    # than reading already-cached rows. These cover subscribe, preview, typed
    # directory search and first-time article extraction per account.
    feed_operation_rate_limit_per_minute: int = 20
    podcast_search_rate_limit_per_minute: int = 30


settings = Settings()
