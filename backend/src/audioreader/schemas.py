"""API request/response shapes, kept deliberately separate from the DB models."""

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, field_validator

from audioreader.commands.intents import MAX_TURNS, Turn
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
    #: Nothing in this feed has audio: every item is text the app reads aloud.
    #: A blog's items are posts, not episodes, and the app names them that way.
    is_article_feed: bool = False
    #: The feed has failed to load repeatedly — it has probably moved or shut
    #: down. Surfaced so the app can say so, rather than leaving her to wonder
    #: why a show she follows has gone quiet.
    is_failing: bool = False
    #: "rss" for anything fetched from the web; "email" for a newsletter that
    #: arrives at her private address. Defaulted so older payloads still read.
    source: str = "rss"
    #: A newsletter that reaches her by way of another inbox's forwarding.
    #: Leaving it in Magpie cannot stop the emails; the rule there can.
    forwarded: bool = False

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


class FeedDiscoveryCandidateRead(BaseModel):
    """One verified feed advertised by a submitted page."""

    title: str
    feed_url: str
    description: str | None = None
    site_url: str | None = None
    format: str
    item_count: int
    audio_item_count: int
    recent_item_titles: list[str] = Field(default_factory=list)
    source: str
    is_primary: bool = False

    @field_validator("description")
    @classmethod
    def plain_description(cls, value: str | None) -> str | None:
        return strip_html(value) if value else value


class FeedDiscoveryRead(BaseModel):
    """All distinct feeds found through one website or feed address."""

    submitted_url: str
    candidates: list[FeedDiscoveryCandidateRead]


class EpisodeRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    #: The item's author, where the feed gives one. Kept distinct from the
    #: containing podcast or publication named by feed_title.
    author: str | None = None
    #: The containing podcast or publication. Optional so every older client
    #: and cached payload remains valid.
    feed_title: str | None = None
    #: Its canonical feed address. Paired with feed_title so clients can make
    #: the publication name a link back to the feed rather than showing the
    #: item author or podcast publisher as inert text.
    feed_url: str | None = None
    audio_url: str | None
    duration_seconds: int | None
    #: Length of a written article when its full text is already known. Null
    #: for audio, old payloads, and teaser-only articles not yet extracted.
    word_count: int | None = None
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
    """An article's full content, to be read aloud or read on screen."""

    episode_id: int
    title: str
    # Paragraphs separated by blank lines; the app chunks on these.
    text: str
    # The same article as sanitised HTML, for showing rather than speaking.
    # Null when only plain text could be recovered — the reader falls back to
    # `text`, so an article is never unreadable for want of markup.
    html: str | None = None


class PodcastSearchResult(BaseModel):
    """One show from the public directory, not yet in our catalog."""

    title: str
    feed_url: str
    publisher: str | None = None
    episode_count: int | None = None
    artwork_url: str | None = None
    itunes_id: int | None = None
    country: str | None = None
    primary_genre: str | None = None
    latest_release_date: datetime | None = None

    @field_validator("artwork_url")
    @classmethod
    def https_only(cls, value: str | None) -> str | None:
        return secure_url(value)


class PublicationSearchRequest(BaseModel):
    """An explicit, user-submitted request for AI-assisted web discovery."""

    query: str = Field(min_length=1, max_length=200)

    @field_validator("query")
    @classmethod
    def not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("query must not be blank")
        return value.strip()


class FeedPreview(BaseModel):
    """A show's page as seen before (or after) subscribing."""

    feed: FeedRead
    episodes: list[EpisodeRead]
    subscribed: bool


class NewsletterAddressRead(BaseModel):
    """The address she gives a newsletter so it reaches the app."""

    address: str


class PendingNewsletterRead(BaseModel):
    """A sender that has written to her address and awaits a yes or no."""

    id: int
    title: str
    sender_address: str
    message_count: int
    latest_title: str | None = None
    latest_at: datetime | None = None


class NewsletterSignupRequest(BaseModel):
    """A newsletter's web page, to sign her address up to."""

    url: HttpUrl


class NewsletterSignupRead(BaseModel):
    """What came of asking a site for its newsletter."""

    #: "submitted", "unsupported" or "failed".
    status: str
    publication: str | None = None
    platform: str | None = None
    address: str | None = None
    #: For "unsupported": account_required, captcha or no_form.
    reason: str | None = None
    spoken_response: str


class InboundReceipt(BaseModel):
    """What became of one email the Worker handed over."""

    status: str
    feed_id: int | None = None
    episode_id: int | None = None


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
    ai_data_sharing_consented: bool = False


class AIDataSharingConsentUpdate(BaseModel):
    granted: bool


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
    transcript: str = Field(max_length=2_000)
    #: Device storefront used for public-directory ranking. Optional for old
    #: clients and hand-written requests, which retain Apple's default.
    country: str | None = Field(default=None, min_length=2, max_length=2)
    #: What she is listening to as she speaks. Without it "mark this as
    #: played" has no referent at all: the backend knows her whole library and
    #: nothing about which part of it is currently coming out of the speaker.
    now_playing_episode_id: int | None = None
    #: What has already been said in this exchange, oldest first, not including
    #: the transcript above. Empty for a request that starts a subject.
    #:
    #: "The one about Agincourt" is not a command; it is the second half of
    #: one. Without these lines the app asks which episode she meant and then
    #: reads her answer as if she had walked up and said it — which is how a
    #: perfectly clear two-sentence request ends in a shrug.
    turns: list[Turn] = Field(default_factory=list)

    @field_validator("transcript")
    @classmethod
    def not_blank(cls, value: str) -> str:
        # Speech recognition can hand us whitespace when it hears nothing;
        # that is not a command, and must not reach the model.
        if not value.strip():
            raise ValueError("transcript must not be blank")
        return value.strip()

    @field_validator("country")
    @classmethod
    def normalised_country(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if not value.isalpha():
            raise ValueError("country must be a two-letter code")
        return value.lower()

    @field_validator("turns")
    @classmethod
    def most_recent(cls, value: list[Turn]) -> list[Turn]:
        # Trimmed rather than rejected: a phone that has been talking for a
        # while is not making a bad request, and refusing it would fail the
        # one turn she is waiting on. The newest lines are the ones that
        # matter, so the oldest go.
        return value[-MAX_TURNS:]


class CommandResponse(BaseModel):
    action: str
    spoken_response: str
    episode: EpisodeRead | None = None
    # For set_speed: the playback rate multiplier the app should apply.
    speed: float | None = None
    #: True when the sentence above is a question: the app should listen again
    #: rather than leaving her to tap and start over. Old apps ignore it and
    #: behave exactly as they did before.
    expects_reply: bool = False


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
    #: Whether silence arrived while Apple was still holding a volatile guess.
    settled_before_finalization: bool | None = None
    #: Seconds spent asking SpeechAnalyzer to finish the captured input.
    finalization_seconds: float | None = None
    #: Whether Apple's final pass changed the transcript shown while listening.
    finalized_transcript_changed: bool | None = None

    # Resolved on the phone, so the server otherwise never learns they happened
    transport_command: str | None = None
    sleep_command: str | None = None

    #: How much had already been said when this turn started: 0 for a fresh
    #: request, higher for an answer to a question the app asked. Pairs with
    #: `conversation_turns` on the server's own span, and is the field that
    #: says whether asking her a question actually leads anywhere.
    conversation_turns: int | None = None

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
