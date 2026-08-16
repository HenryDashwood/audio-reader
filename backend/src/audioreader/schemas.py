"""API request/response shapes, kept deliberately separate from the DB models."""

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, HttpUrl, field_validator

from audioreader.text import strip_html


def secure_url(url: str | None) -> str | None:
    """Upgrade http:// to https://.

    iOS App Transport Security refuses plain HTTP, so an http:// enclosure
    simply will not play and http:// artwork silently shows a placeholder.
    Every major podcast host serves the same asset over TLS; only the scheme
    is touched, since paths legitimately contain the substring "http".
    """
    if url and url.startswith("http://"):
        return "https://" + url[len("http://") :]
    return url


class FeedCreate(BaseModel):
    url: HttpUrl


class FeedRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    url: str
    title: str
    description: str | None
    image_url: str | None
    episode_count: int
    #: The feed has failed to load repeatedly — it has probably moved or shut
    #: down. Surfaced so the app can say so, rather than leaving her to wonder
    #: why a show she follows has gone quiet.
    is_failing: bool = False

    @field_validator("description")
    @classmethod
    def plain_text(cls, value: str | None) -> str | None:
        # Feeds carry HTML; clients should get something they can display
        # directly rather than each having to parse markup.
        return strip_html(value) if value else value

    @field_validator("image_url")
    @classmethod
    def https_only(cls, value: str | None) -> str | None:
        return secure_url(value)


class EpisodeRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    audio_url: str | None
    duration_seconds: int | None
    published_at: datetime | None
    link: str | None
    # Per-episode artwork; the routers fall back to the show's artwork when
    # the feed does not provide item-level images.
    image_url: str | None = None
    # The requesting user's playback position, filled in by the routers from
    # playback_positions; None means never played.
    position_seconds: float | None = None
    completed: bool = False
    #: She asked for this one to go without hearing it. Distinct from
    #: completed: both leave the feed, only one is a claim about listening.
    dismissed: bool = False
    # True when the episode can be read aloud as an article — the app's cue
    # that an item with no audio_url is still playable, via text-to-speech.
    has_text: bool = False

    @field_validator("description")
    @classmethod
    def plain_text(cls, value: str | None) -> str | None:
        return strip_html(value) if value else value

    @field_validator("audio_url", "image_url")
    @classmethod
    def https_only(cls, value: str | None) -> str | None:
        return secure_url(value)


class EpisodeTextRead(BaseModel):
    """An article's full text, ready to be read aloud by the app."""

    episode_id: int
    title: str
    # Paragraphs separated by blank lines; the app chunks on these.
    text: str


class PodcastSearchResult(BaseModel):
    """One show from the public directory, not yet in our catalog."""

    title: str
    feed_url: str
    publisher: str | None = None
    episode_count: int | None = None
    artwork_url: str | None = None

    @field_validator("artwork_url")
    @classmethod
    def https_only(cls, value: str | None) -> str | None:
        return secure_url(value)


class FeedPreview(BaseModel):
    """A show's page as seen before (or after) subscribing."""

    feed: FeedRead
    episodes: list[EpisodeRead]
    subscribed: bool


class AppleLoginRequest(BaseModel):
    identity_token: str
    #: Apple's one-time authorization code, traded for the refresh token that
    #: makes revoking her grant possible when she deletes her account.
    #: Optional: older builds of the app do not send it, and a sign-in without
    #: one must still work.
    authorization_code: str | None = None


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    display_name: str | None


class AuthResponse(BaseModel):
    token: str
    user: UserRead


class PositionUpdate(BaseModel):
    position_seconds: float
    completed: bool = False

    @field_validator("position_seconds")
    @classmethod
    def non_negative(cls, value: float) -> float:
        # A scrubber can briefly report negative time; clamp rather than 422,
        # since the app fires these in the background and never sees the error.
        return max(0.0, value)


class EpisodeStateUpdate(BaseModel):
    """How an episode is filed. Omitted fields are left as they were.

    Two independent flags rather than one state, because they answer different
    questions — "have I heard this?" and "do I want to see this?" — and an
    episode can be either without being the other.
    """

    played: bool | None = None
    dismissed: bool | None = None


class CommandRequest(BaseModel):
    transcript: str
    #: What she is listening to as she speaks. Without it "mark this as
    #: played" has no referent at all: the backend knows her whole library and
    #: nothing about which part of it is currently coming out of the speaker.
    now_playing_episode_id: int | None = None

    @field_validator("transcript")
    @classmethod
    def not_blank(cls, value: str) -> str:
        # Speech recognition can hand us whitespace when it hears nothing;
        # that is not a command, and must not reach the model.
        if not value.strip():
            raise ValueError("transcript must not be blank")
        return value.strip()


class CommandResponse(BaseModel):
    action: str
    spoken_response: str
    episode: EpisodeRead | None = None
    # For set_speed: the playback rate multiplier the app should apply.
    speed: float | None = None


class VoiceAttemptEvent(BaseModel):
    """One spoken request, as the phone experienced it.

    The client half of the wide event in `routers/commands.py`. Most of what
    goes wrong with a spoken request goes wrong before the backend hears about
    it — the microphone not waking, the recogniser producing nothing, a
    transport word resolving on the phone — and none of that is visible in a
    request that was never made. This is that missing row.

    Deliberately flat and deliberately wide: one row per attempt, answerable
    without a join, in the same shape as the server's own event. Fields are
    optional because an attempt can end at any point, and a half-finished
    attempt is exactly the one worth keeping.
    """

    # What happened, in her terms. The one field to group by.
    outcome: str
    #: True when the attempt never got as far as POST /command, which until now
    #: made it invisible: the whole failure was an absence of a request.
    command_sent: bool = False

    # Speech
    recogniser: str | None = None
    used_fallback: bool = False
    #: Milliseconds between starting capture and the first audio buffer. The
    #: measurement that would have found the go-ahead-before-live bug in
    #: minutes rather than a night: it is null exactly when the microphone
    #: never came up.
    audio_first_buffer_ms: int | None = None
    listen_seconds: float | None = None
    transcript_empty: bool | None = None
    #: Whether the recogniser had committed to its transcript when the turn
    #: ended, or was still revising and got cut off mid-thought.
    settled_at_end: bool | None = None

    # Resolved on the phone, so the server otherwise never learns they happened
    transport_command: str | None = None
    sleep_command: str | None = None

    # Context that turned out to matter while debugging
    voiceover: bool | None = None
    #: The first request since launch is the one that kept failing, so it has
    #: to be distinguishable from the retry that worked.
    first_since_launch: bool | None = None
    app_version: str | None = None
    app_build: str | None = None

    total_seconds: float | None = None
    error: str | None = None

    @field_validator("outcome", "recogniser", "transport_command", "sleep_command", "error")
    @classmethod
    def bounded(cls, value: str | None) -> str | None:
        """Keep these columns low-cardinality and small.

        They are the ones worth grouping by, which stops working the moment
        something free-form ends up in them. Nothing here should ever be a
        transcript — that is the server's to record, once, under a setting the
        privacy policy is written against.
        """
        if value is None:
            return None
        value = value.strip()[:64]
        return value or None


class DiagnosticEvent(BaseModel):
    """A crash or hang, as the phone's own diagnostics described it.

    From Apple's MetricKit, which delivers these in a daily batch — so this
    answers "what has been crashing" and never "why did that just fail".
    Deliberately the summary rather than the whole payload: the rest is call
    stacks that mean nothing without the matching dSYM, and are not worth
    uploading from a phone.

    She will never report a crash. From the inside, a crash and the app being
    closed are the same silence.
    """

    kind: str
    signal: int | None = None
    exception_type: int | None = None
    exception_code: int | None = None
    termination_reason: str | None = None
    #: The line that names an out-of-memory or a guarded-resource kill
    #: outright, rather than leaving it to be inferred from a stack.
    virtual_memory_region: str | None = None
    hang_seconds: float | None = None
    app_version: str | None = None
    os_version: str | None = None
    window_end: str | None = None

    @field_validator("kind", "termination_reason", "app_version", "os_version")
    @classmethod
    def bounded(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()[:128]
        return value or None

    @field_validator("virtual_memory_region")
    @classmethod
    def bounded_region(cls, value: str | None) -> str | None:
        # Longer than the rest because it is prose from the OS, and truncating
        # it to nothing would remove the only field that explains itself.
        if value is None:
            return None
        value = value.strip()[:2000]
        return value or None
