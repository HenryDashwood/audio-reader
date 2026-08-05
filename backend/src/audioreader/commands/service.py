"""Turn a spoken request into an action, using an LLM to pick the episode."""

import logging

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from audioreader.commands.intents import Action, Candidate, InterpretResult, ModelDecision
from audioreader.config import settings
from audioreader.models import Episode
from audioreader.text import summarise

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You help a blind listener control a podcast app by voice.

You will be given what she said and a numbered list of episodes she subscribes
to. Decide which episode she means and reply with the matching action.

- Choose play_episode only when one episode is a clear match. She may refer to
  an episode by topic, by guest, by date ("Tuesday's one"), or by position
  ("the latest"). Prefer the most recent episode when a request is ambiguous
  between several of the same show.
- Choose unknown when nothing matches, or when several episodes match equally
  well and guessing would be worse than asking.
- episode_id must be copied exactly from the list. Never invent one.
- spoken_response is read aloud to her, so keep it to one short sentence. For
  play_episode, name the episode and show so she can tell if you got it wrong.
  For unknown, say briefly what you need her to clarify.
"""


async def build_candidates(session: AsyncSession, limit: int | None = None) -> list[Candidate]:
    """The episodes the model may choose between, newest first.

    Only episodes with audio: article text-to-speech is a later increment, so
    offering an article here would produce an action the app cannot perform.
    """
    limit = limit if limit is not None else settings.command_candidate_limit
    episodes = await session.scalars(
        select(Episode)
        .where(Episode.audio_url.is_not(None))
        .options(joinedload(Episode.feed))
        .order_by(Episode.published_at.desc().nulls_last(), Episode.id.desc())
        .limit(limit)
    )
    return [
        Candidate(
            id=episode.id,
            title=episode.title,
            feed_title=episode.feed.title,
            # The model sees stripped, truncated text: feed descriptions are
            # HTML soup and would otherwise dominate the token bill.
            description=summarise(episode.description, limit=300),
            published_at=episode.published_at,
            duration_seconds=episode.duration_seconds,
        )
        for episode in episodes
    ]


def build_prompt(transcript: str, candidates: list[Candidate]) -> str:
    lines = ["She said:", f'"{transcript}"', "", "Episodes she subscribes to:"]
    for candidate in candidates:
        published = (
            candidate.published_at.strftime("%A %d %B %Y") if candidate.published_at else "undated"
        )
        duration = (
            f"{round(candidate.duration_seconds / 60)} min" if candidate.duration_seconds else ""
        )
        header = f"[{candidate.id}] {candidate.title} — {candidate.feed_title} — {published}"
        lines.append(f"{header} — {duration}" if duration else header)
        if candidate.description:
            lines.append(f"    {candidate.description}")
    return "\n".join(lines)


async def interpret(session: AsyncSession, llm, transcript: str) -> InterpretResult:
    candidates = await build_candidates(session)
    if not candidates:
        # Nothing to choose from, so there is nothing for the model to do.
        return InterpretResult(
            action=Action.UNKNOWN,
            spoken_response="You have no podcast episodes yet. Try subscribing to a show first.",
        )

    raw = await llm.decide(
        system=SYSTEM_PROMPT,
        user=build_prompt(transcript, candidates),
        output_model=ModelDecision,
    )

    try:
        decision = ModelDecision.model_validate(raw)
    except ValidationError as exc:
        logger.warning("model returned an unusable decision (%s): %r", exc, raw)
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    if decision.action is not Action.PLAY_EPISODE:
        return InterpretResult(action=Action.UNKNOWN, spoken_response=decision.spoken_response)

    # Never trust the model with a primary key: only ids we offered are valid.
    if decision.episode_id not in {candidate.id for candidate in candidates}:
        logger.warning("model chose episode_id %r, which was not offered", decision.episode_id)
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    episode = await session.get(Episode, decision.episode_id)
    if episode is None:
        return InterpretResult(action=Action.UNKNOWN, spoken_response=_CLARIFY)

    return InterpretResult(
        action=Action.PLAY_EPISODE,
        spoken_response=decision.spoken_response,
        episode=episode,
    )


_CLARIFY = "Sorry, I did not catch which episode you meant. Could you say that again?"
