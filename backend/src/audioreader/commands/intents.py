"""What the model is allowed to decide, and what we hand back to the app."""

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field

from audioreader.models import Episode


class Action(StrEnum):
    PLAY_EPISODE = "play_episode"
    UNKNOWN = "unknown"


class ModelDecision(BaseModel):
    """The schema the model is constrained to. Deliberately tiny.

    episode_id is only meaningful for PLAY_EPISODE, and is always checked
    against the candidate list before we act on it.
    """

    action: Action
    episode_id: int | None = None
    spoken_response: str = Field(
        description="One short sentence to read aloud, naming the episode if one was chosen."
    )


@dataclass
class Candidate:
    """One episode as the model sees it."""

    id: int
    title: str
    feed_title: str
    description: str
    published_at: datetime | None
    duration_seconds: int | None


@dataclass
class InterpretResult:
    action: Action
    spoken_response: str
    episode: Episode | None = None
