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


class CommandRequest(BaseModel):
    transcript: str

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
