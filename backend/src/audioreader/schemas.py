"""API request/response shapes, kept deliberately separate from the DB models."""

from datetime import datetime

from pydantic import BaseModel, ConfigDict, HttpUrl, field_validator


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


class EpisodeRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    audio_url: str | None
    duration_seconds: int | None
    published_at: datetime | None
    link: str | None


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
