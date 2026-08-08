"""API request/response shapes, kept deliberately separate from the DB models."""

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

    @field_validator("description")
    @classmethod
    def plain_text(cls, value: str | None) -> str | None:
        return strip_html(value) if value else value

    @field_validator("audio_url")
    @classmethod
    def https_only(cls, value: str | None) -> str | None:
        return secure_url(value)


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
