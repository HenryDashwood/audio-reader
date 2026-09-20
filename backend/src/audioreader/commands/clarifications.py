"""Stable choices and single-use continuations, independent of the model provider."""

import json
import re
import uuid
from datetime import timedelta

from sqlalchemy import delete, select, update

from audioreader.commands.intents import Action, Clarification, ClarificationChoice, CommandStatus, InterpretResult
from audioreader.models import Feed, Subscription, VoiceClarification, utcnow
from audioreader.newsletters import service as newsletters

ACTIONS = [
    "play_episode",
    "mark_played",
    "dismiss",
    "restore",
    "unsubscribe",
    "approve_newsletter",
    "block_newsletter",
    "other",
]


def words(text: str) -> str:
    return " ".join(re.findall(r"[\w]+", text.casefold()))


def choice_for(question: Clarification, answer: str, selected_id: str | None = None) -> str | None:
    """Only exact labels, distinguishing words and explicit ordinals bypass a model."""
    if selected_id is not None:
        return selected_id if any(item.id == selected_id for item in question.choices) else None
    answer = words(answer)
    ordinals = {
        "first": 0,
        "the first one": 0,
        "one": 0,
        "1": 0,
        "second": 1,
        "the second one": 1,
        "two": 1,
        "2": 1,
        "third": 2,
        "the third one": 2,
        "three": 2,
        "3": 2,
    }
    if answer in ordinals:
        index = ordinals[answer]
        return question.choices[index].id if index < len(question.choices) else None
    if not answer or set(answer.split()) & {"no", "not", "neither", "except", "yes", "cancel"}:
        return None
    matches = [item for item in question.choices if words(item.label) == answer]
    if not matches:
        matches = [item for item in question.choices if set(answer.split()) <= set(words(item.label).split())]
    return matches[0].id if len(matches) == 1 else None


async def create(
    session, user, *, action, target_ids, question, remaining_request, candidates, request, date_window=None
):
    if action not in ACTIONS or not isinstance(question, str) or not 1 <= len(question) <= 500:
        raise ValueError("Provide a supported action and one brief question")
    if not isinstance(remaining_request, str) or len(remaining_request) > 2000:
        raise ValueError("The remaining request must be short")
    if not isinstance(target_ids, list) or len(target_ids) > 3 or any(type(i) is not int for i in target_ids):
        raise ValueError("Offer up to three supplied IDs")
    if len(set(target_ids)) != len(target_ids):
        raise ValueError("Choices must be distinct")
    if action == "other" and target_ids:
        raise ValueError("An open question cannot supply target IDs")
    if action != "other" and len(target_ids) < 2:
        raise ValueError("A bounded choice needs two or three alternatives")
    choices, calls = [], {}
    feeds = {}
    if action == "unsubscribe":
        feeds = {
            f.id: f
            for f in await session.scalars(
                select(Feed)
                .join(Subscription, Subscription.feed_id == Feed.id)
                .where(Subscription.user_id == user.id, Subscription.group_feed_id.is_(None))
            )
        }
    elif action in {"approve_newsletter", "block_newsletter"}:
        feeds = {item.feed.id: item.feed for item in await newsletters.pending_senders(session, user)}
    episodes = {item.id: item for item in candidates}
    for target_id in target_ids:
        option_id = str(target_id)
        if action in {"play_episode", "mark_played", "dismiss", "restore"}:
            candidate = episodes.get(target_id)
            if candidate is None:
                raise ValueError("Episode was not supplied")
            label = f"{candidate.title} — {candidate.feed_title}"
            name = "play_episode" if action == "play_episode" else "file_episode"
            args = {"episode_id": target_id}
            if date_window:
                args.update(published_after=date_window[0].isoformat(), published_before=date_window[1].isoformat())
            if name == "file_episode":
                args["action"] = action
        else:
            feed = feeds.get(target_id)
            if feed is None:
                raise ValueError("Target is no longer available to this user")
            label = feed.title
            name = "unsubscribe_from_feed" if action == "unsubscribe" else action
            args = {"feed_id" if action == "unsubscribe" else "newsletter_id": target_id}
        choices.append(ClarificationChoice(id=option_id, label=label))
        calls[option_id] = {"name": name, "arguments": args}
    # Repeated episode titles need a fact the user can distinguish, not two
    # identical labels whose only difference is an internal database ID.
    duplicated = {item.label for item in choices if sum(other.label == item.label for other in choices) > 1}
    for item in choices:
        if item.label in duplicated and (episode := episodes.get(int(item.id))) and episode.published_at:
            item.label += f" — {episode.published_at.day} {episode.published_at.strftime('%B %Y')}"
    if len({item.label for item in choices}) != len(choices):
        raise ValueError("These choices have no distinguishing title or date. Ask an open question instead.")
    # Bounded questions name the exact choices, rather than trusting model prose
    # to describe a different action or ordering from the machine-readable list.
    if choices:
        question = "Did you mean " + " or ".join(item.label for item in choices) + "?"
    public = Clarification(
        id=str(uuid.uuid4()), question=question, choices=choices, expires_at=utcnow() + timedelta(minutes=10)
    )
    payload = {
        "public": public.model_dump(mode="json"),
        "calls": calls,
        "remaining_request": remaining_request,
        "request": request,
    }
    await session.execute(
        delete(VoiceClarification).where(
            VoiceClarification.user_id == user.id, VoiceClarification.expires_at < utcnow()
        )
    )
    session.add(
        VoiceClarification(id=public.id, user_id=user.id, expires_at=public.expires_at, payload=json.dumps(payload))
    )
    await session.commit()
    return InterpretResult(
        Action.UNKNOWN, question, expects_reply=True, status=CommandStatus.NEEDS_CLARIFICATION, clarification=public
    )


async def load(session, user, clarification_id):
    row = await session.scalar(
        select(VoiceClarification).where(
            VoiceClarification.id == clarification_id,
            VoiceClarification.user_id == user.id,
            VoiceClarification.consumed.is_(False),
            VoiceClarification.expires_at > utcnow(),
        )
    )
    return json.loads(row.payload) if row else None


async def claim(session, user, clarification_id):
    # Atomic across workers/devices. An interrupted claim is not automatically
    # replayed; /command request receipts recover the outcome of that attempt.
    result = await session.execute(
        update(VoiceClarification)
        .where(
            VoiceClarification.id == clarification_id,
            VoiceClarification.user_id == user.id,
            VoiceClarification.consumed.is_(False),
            VoiceClarification.expires_at > utcnow(),
        )
        .values(consumed=True)
        .returning(VoiceClarification.id)
    )
    claimed = result.scalar_one_or_none() is not None
    await session.commit()
    return claimed


def unavailable():
    return InterpretResult(
        Action.UNKNOWN,
        "That question has expired or was already answered. Please ask again.",
        status=CommandStatus.NOT_FOUND,
    )
