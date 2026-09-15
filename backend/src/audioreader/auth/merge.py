"""Combine accounts only after a live session and verified provider proof.

The caller locks both users and commits once. The current account keeps its ID
and sessions; the other account's sessions are removed, so stale devices cannot
write their cached selections into the combined library.
"""

from datetime import UTC, datetime

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import (
    AppleBrowserFlow,
    ArticleContent,
    AuthSession,
    Feed,
    InboundMessage,
    NewsletterInboxAlias,
    NewsletterSignup,
    PlaybackPosition,
    SavedArticle,
    Subscription,
    User,
    UserIdentity,
    VoiceCommandReceipt,
    VoiceUndo,
    utcnow,
)


def aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)


async def combine_accounts(session: AsyncSession, target: User, source: User) -> None:
    await _subscriptions(session, target, source)
    await _saved_and_positions(session, target, source)

    # Keep every immutable capture, including a duplicate's unselected version.
    for table, owner in ((ArticleContent, ArticleContent.owner_user_id), (Feed, Feed.owner_user_id)):
        await session.execute(update(table).where(owner == source.id).values(owner_user_id=target.id))
    for table in (InboundMessage, NewsletterSignup, NewsletterInboxAlias, UserIdentity):
        await session.execute(update(table).where(table.user_id == source.id).values(user_id=target.id))

    if source.inbound_token:
        token = source.inbound_token
        if await session.get(NewsletterInboxAlias, token) is None:
            session.add(NewsletterInboxAlias(token=token, user_id=target.id, namespace_user_id=source.id))
        source.inbound_token = None
        await session.flush()  # release the users table's unique address before moving it
        if target.inbound_token is None:
            target.inbound_token = token
    target.display_name = target.display_name or source.display_name
    target.email = target.email or source.email
    # Combining libraries never broadens an existing AI-sharing permission.
    # Ask again for the newly combined library, even if one account consented.
    target.ai_data_sharing_withdrawn_at = utcnow()

    # A saved undo payload describes the old library. Replaying it after a
    # merge could remove imported subscriptions. Keep target command receipts
    # (retry deduplication), but invalidate both accounts' undo state.
    await session.execute(delete(VoiceUndo).where(VoiceUndo.user_id.in_([target.id, source.id])))
    for table in (AppleBrowserFlow, AuthSession, VoiceCommandReceipt):
        await session.execute(delete(table).where(table.user_id == source.id))
    await session.flush()
    await session.execute(delete(User).where(User.id == source.id))


async def _subscriptions(session: AsyncSession, target: User, source: User) -> None:
    current = {
        s.feed_id: s for s in await session.scalars(select(Subscription).where(Subscription.user_id == target.id))
    }
    incoming = list(await session.scalars(select(Subscription).where(Subscription.user_id == source.id)))
    for subscription in incoming:
        duplicate = current.get(subscription.feed_id)
        if duplicate is None:
            subscription.user_id = target.id
            current[subscription.feed_id] = subscription
        else:
            cursors = [
                v for v in (duplicate.latest_after_episode_id, subscription.latest_after_episode_id) if v is not None
            ]
            duplicate.latest_after_episode_id = max(cursors) if cursors else None
            duplicate.created_at = min(duplicate.created_at, subscription.created_at, key=aware)
            await session.delete(subscription)
    # Prefer the current account's group on overlaps. Flatten imported groups
    # through those roots, without introducing cycles or orphaned children.
    for subscription in current.values():
        root = subscription.group_feed_id
        visited = {subscription.feed_id}
        while root is not None and root in current and root not in visited:
            visited.add(root)
            parent = current[root].group_feed_id
            if parent is None:
                break
            root = parent
        subscription.group_feed_id = (
            root
            if root in current and root not in {subscription.feed_id} and current[root].group_feed_id is None
            else None
        )
    await session.flush()


async def _saved_and_positions(session: AsyncSession, target: User, source: User) -> None:
    selections = {
        s.episode_id: s for s in await session.scalars(select(SavedArticle).where(SavedArticle.user_id == target.id))
    }
    for saved in await session.scalars(select(SavedArticle).where(SavedArticle.user_id == source.id)):
        duplicate = selections.get(saved.episode_id)
        if duplicate is None:
            saved.user_id = target.id
            selections[saved.episode_id] = saved
        else:
            # Keep the current account's readable copy. A failed/empty capture
            # can be repaired by the other account's prepared text.
            if duplicate.content_id is None and saved.content_id is not None:
                duplicate.content_id = saved.content_id
                duplicate.capture_error = saved.capture_error
            dates = [date for date in (duplicate.saved_at, saved.saved_at) if date is not None]
            duplicate.saved_at = min(dates, key=aware) if dates else None
            await session.delete(saved)
    await session.flush()

    positions = list(
        await session.scalars(select(PlaybackPosition).where(PlaybackPosition.user_id.in_([target.id, source.id])))
    )
    winners: dict[int, PlaybackPosition] = {}
    for position in positions:
        selected = selections.get(position.episode_id)
        if selected is not None and selected.content_id != position.content_id:
            continue  # seconds from a different text version must never carry over
        previous = winners.get(position.episode_id)
        if previous is None or (aware(position.updated_at), position.user_id == target.id) > (
            aware(previous.updated_at),
            previous.user_id == target.id,
        ):
            winners[position.episode_id] = position
    for position in positions:
        if winners.get(position.episode_id) is not position:
            await session.delete(position)
    await session.flush()  # remove duplicate composite keys before moving winners
    for position in winners.values():
        if position.user_id != target.id:
            # Preserve the timestamp: changing the owner is not playback.
            await session.execute(
                update(PlaybackPosition)
                .where(PlaybackPosition.user_id == source.id, PlaybackPosition.episode_id == position.episode_id)
                .values(user_id=target.id, updated_at=position.updated_at)
            )
    await session.flush()
