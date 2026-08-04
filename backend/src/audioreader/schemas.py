"""API request/response shapes, kept deliberately separate from the DB models."""

from datetime import datetime

from pydantic import BaseModel, ConfigDict, HttpUrl


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
