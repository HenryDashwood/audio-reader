"""What the model is allowed to decide, and what we hand back to the app."""

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field

from audioreader.models import Episode


class Action(StrEnum):
    PLAY_EPISODE = "play_episode"
    PLAY_FROM_SHOW = "play_from_show"
    SUBSCRIBE = "subscribe"
    UNSUBSCRIBE = "unsubscribe"
    SET_SPEED = "set_speed"
    # Outcome actions, produced by us rather than chosen by the model.
    SUBSCRIBED = "subscribed"
    UNSUBSCRIBED = "unsubscribed"
    UNKNOWN = "unknown"


#: What the model is allowed to choose. Outcomes are ours to decide.
MODEL_ACTIONS = (
    Action.PLAY_EPISODE,
    Action.PLAY_FROM_SHOW,
    Action.SUBSCRIBE,
    Action.UNSUBSCRIBE,
    Action.SET_SPEED,
    Action.UNKNOWN,
)


class ModelDecision(BaseModel):
    """The schema the model is constrained to. Deliberately tiny.

    episode_id is only meaningful for PLAY_EPISODE, and is always checked
    against the candidate list before we act on it. search_query is only
    meaningful for SUBSCRIBE, UNSUBSCRIBE and PLAY_FROM_SHOW; episode_query
    only for PLAY_FROM_SHOW. speed is only meaningful for SET_SPEED.
    """

    action: Action
    episode_id: int | None = None
    search_query: str | None = Field(
        default=None,
        description="For subscribe, unsubscribe and play_from_show: the show's"
        " name as she said it, nothing else.",
    )
    episode_query: str | None = Field(
        default=None,
        description="For play_from_show: which episode she described, or empty for the latest.",
    )
    speed: float | None = Field(
        default=None,
        description="For set_speed: the playback rate multiplier, e.g. 1.5 for"
        " one and a half times normal speed.",
    )
    spoken_response: str = Field(
        description="One short sentence to read aloud, naming the episode if one was chosen."
    )


@dataclass
class Candidate:
    """One episode or article as the model sees it."""

    id: int
    title: str
    feed_title: str
    description: str
    published_at: datetime | None
    duration_seconds: int | None
    # An item with no audio, read aloud by the app instead of streamed.
    is_article: bool = False


@dataclass
class InterpretResult:
    action: Action
    spoken_response: str
    episode: Episode | None = None
    speed: float | None = None
