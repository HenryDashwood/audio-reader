"""One exact inverse for the most recent reversible voice action."""

import json
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import joinedload

from audioreader.commands.intents import Action, InterpretResult
from audioreader.models import Episode, Feed, PlaybackPosition, Subscription, VoiceUndo, utcnow


async def snapshot(session, user, name, args):
    if name == "file_episode":
        episode_id = int(args.get("episode_id", 0))
        row = await session.get(PlaybackPosition, (user.id, episode_id))
        return {"kind": "filing", "episode_id": episode_id, "before": state(row)}
    if name in {"subscribe_to_feed", "unsubscribe_from_feed"}:
        rows = list(await session.scalars(select(Subscription).where(Subscription.user_id == user.id)))
        return {
            "kind": "subscription",
            "before": [row.feed_id for row in rows],
            "cursors": {str(row.feed_id): row.latest_after_episode_id for row in rows},
        }
    return None


def state(row):
    return {
        "completed": bool(row and row.completed),
        "dismissed": bool(row and row.dismissed),
        "position_seconds": row.position_seconds if row else 0.0,
    }


async def remember(session, user, before):
    if before is None:
        previous = await session.get(VoiceUndo, user.id)
        if previous is not None:
            await session.delete(previous)
            await session.commit()
        return
    if before["kind"] == "filing":
        row = await session.get(PlaybackPosition, (user.id, before["episode_id"]))
        before["after"] = state(row)
    else:
        after = set(await session.scalars(select(Subscription.feed_id).where(Subscription.user_id == user.id)))
        old = set(before["before"])
        changed = old ^ after
        if len(changed) != 1:
            await remember(session, user, None)
            return
        feed_id = next(iter(changed))
        feed = await session.get(Feed, feed_id)
        # Leaving email senders may already have submitted an unsubscribe.
        if feed is None or feed.source == "email":
            await remember(session, user, None)
            return
        before = {
            "kind": "subscription",
            "feed_id": feed_id,
            "was_following": feed_id in old,
            "latest_after_episode_id": before["cursors"].get(str(feed_id)),
        }
    row = await session.get(VoiceUndo, user.id)
    if row is None:
        row = VoiceUndo(user_id=user.id)
        session.add(row)
    before["recorded_at"] = utcnow().isoformat()
    row.payload = json.dumps(before)
    await session.commit()


async def undo_last(session, user):
    row = await session.get(VoiceUndo, user.id)
    if row is None:
        return InterpretResult(Action.UNKNOWN, "There is no recent reversible voice action to undo.")
    saved = json.loads(row.payload)
    if (utcnow() - datetime.fromisoformat(saved["recorded_at"])).total_seconds() > 600:
        return InterpretResult(Action.UNKNOWN, "That action is too old to undo by voice.")
    if saved["kind"] == "filing":
        episode_id = saved["episode_id"]
        position = await session.get(PlaybackPosition, (user.id, episode_id))
        if state(position) != saved["after"]:
            return InterpretResult(Action.UNKNOWN, "That item has changed since then. I left it as it is.")
        episode = await session.get(Episode, episode_id, options=[joinedload(Episode.feed)])
        if position is None or episode is None:
            return InterpretResult(Action.UNKNOWN, "That item is no longer available to undo.")
        for key, value in saved["before"].items():
            setattr(position, key, value)
        position.updated_at = utcnow()
        action = Action.MARK_PLAYED if position.completed else Action.DISMISS if position.dismissed else Action.RESTORE
        result = InterpretResult(action, f"Undid the change to {episode.title}.", episode)
    else:
        feed_id = saved["feed_id"]
        feed = await session.get(Feed, feed_id)
        subscription = await session.scalar(
            select(Subscription).where(Subscription.user_id == user.id, Subscription.feed_id == feed_id)
        )
        if feed is None or bool(subscription) == saved["was_following"]:
            return InterpretResult(Action.UNKNOWN, "That subscription has already changed. I left it as it is.")
        if saved["was_following"]:
            session.add(
                Subscription(
                    user_id=user.id, feed_id=feed_id, latest_after_episode_id=saved.get("latest_after_episode_id")
                )
            )
            result = InterpretResult(Action.SUBSCRIBED, f"Following {feed.title} again.")
        else:
            await session.delete(subscription)
            result = InterpretResult(Action.UNSUBSCRIBED, f"Undid following {feed.title}.")
    await session.delete(row)
    await session.commit()
    return result
