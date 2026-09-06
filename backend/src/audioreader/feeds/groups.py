"""Listener-owned source groups, without moving or sharing article records.

Only explicitly combined subscriptions participate. Publisher names and
article titles are never sufficient evidence that two items are the same.
"""

import uuid
from dataclasses import dataclass, field
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import Episode, Feed, PlaybackPosition, Subscription, User
from audioreader.text import strip_html


def article_key(link: str | None) -> str | None:
    if not link:
        return None
    try:
        url = urlsplit(link)
        if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password:
            return None
        port = url.port
    except ValueError:
        return None
    host = url.hostname.lower()
    if port not in {None, 80, 443}:
        host = f"{host}:{port}"
    # Keep content-identifying query parameters (notably WordPress's ?p=).
    query = sorted(
        (key, value)
        for key, value in parse_qsl(url.query, keep_blank_values=True)
        if not key.lower().startswith("utm_") and key.lower() not in {"fbclid", "gclid", "mc_cid", "mc_eid"}
    )
    return urlunsplit(("https", host, url.path.rstrip("/") or "/", urlencode(query), ""))


@dataclass
class Catalog:
    roots: dict[int, int] = field(default_factory=dict)
    feeds: dict[int, Feed] = field(default_factory=dict)
    cursors: dict[int, int | None] = field(default_factory=dict)
    episode_feeds: dict[int, int] = field(default_factory=dict)
    representatives: dict[int, int] = field(default_factory=dict)
    copies: dict[int, list[int]] = field(default_factory=dict)

    @property
    def excluded_ids(self) -> list[int]:
        return [item_id for item_id, preferred in self.representatives.items() if item_id != preferred]

    def feed_ids(self, root: int) -> list[int]:
        return [feed_id for feed_id, group in self.roots.items() if group == root] or [root]

    def latest_ids(self) -> list[int]:
        # A late-arriving second copy must not resurrect an article already
        # cleared or present when its source was followed.
        return [
            preferred
            for preferred, ids in self.copies.items()
            if all(
                (cursor := self.cursors.get(self.episode_feeds[item_id])) is None or item_id > cursor
                for item_id in ids
            )
        ]

    def equivalents(self, item_id: int) -> list[int]:
        return self.copies.get(self.representatives.get(item_id, item_id), [item_id])


async def catalog(session: AsyncSession, user_id: uuid.UUID) -> Catalog:
    # Reuse the same view throughout a request (counts, rows, state, voice).
    # A commit starts a different transaction, so this never outlives a poll,
    # grouping change or subscription edit, even in a reused session.
    transaction = session.sync_session.get_transaction()
    cached = session.info.get("feed_group_catalog")
    if transaction is not None and cached is not None and cached[0] is transaction and cached[1] == user_id:
        return cached[2]
    result = await _catalog(session, user_id)
    session.info["feed_group_catalog"] = (session.sync_session.get_transaction(), user_id, result)
    return result


async def _catalog(session: AsyncSession, user_id: uuid.UUID) -> Catalog:
    subscriptions = list(await session.scalars(select(Subscription).where(Subscription.user_id == user_id)))
    roots = {s.group_feed_id for s in subscriptions if s.group_feed_id is not None}
    result = Catalog()
    if not roots:
        return result
    for subscription in subscriptions:
        root = subscription.group_feed_id or subscription.feed_id
        if root in roots:
            result.roots[subscription.feed_id] = root
            result.cursors[subscription.feed_id] = subscription.latest_after_episode_id
    feeds = list(await session.scalars(select(Feed).where(Feed.id.in_(result.roots))))
    result.feeds = {feed.id: feed for feed in feeds}
    for feed in feeds:
        if feed.companion_feed_id is not None:
            # An automatically linked email companion remains part of its
            # newsletter when that newsletter is explicitly grouped.
            result.roots.setdefault(feed.companion_feed_id, result.roots[feed.id])
            result.cursors.setdefault(feed.companion_feed_id, feed.companion_latest_after_episode_id)
    rows = (
        await session.execute(
            select(
                Episode.id, Episode.feed_id, Episode.link, Episode.content_html, Episode.description, Episode.title
            ).where(Episode.feed_id.in_(result.roots))
        )
    ).all()
    buckets: dict[tuple[int, str | int], list[tuple[int, int, int]]] = {}
    for item_id, feed_id, link, content, description, _ in rows:
        root = result.roots[feed_id]
        result.episode_feeds[item_id] = feed_id
        key = (root, article_key(link) or item_id)
        size = len(strip_html(content or description or ""))
        buckets.setdefault(key, []).append((item_id, feed_id, size))
    parents = {row[0]: row[0] for row in rows}

    def representative(item_id: int) -> int:
        while parents[item_id] != item_id:
            parents[item_id] = parents[parents[item_id]]
            item_id = parents[item_id]
        return item_id

    def join(left: int, right: int) -> None:
        parents[representative(left)] = representative(right)

    for items in buckets.values():
        # Do not collapse a publisher's distinct entries within one source.
        if len({feed_id for _, feed_id, _ in items}) > 1:
            for item_id, _, _ in items[1:]:
                join(items[0][0], item_id)

    # Preserve the existing email-companion rule for tracking links. Title
    # matching is confined to these already-established newsletter pairs;
    # explicitly combined feeds still require matching article URLs.
    from audioreader.newsletters.companions import _title_key

    for feed in feeds:
        if feed.companion_feed_id is None:
            continue
        own_titles = {_title_key(row[5]): row[0] for row in rows if row[1] == feed.id}
        for row in rows:
            if row[1] == feed.companion_feed_id and (own_id := own_titles.get(_title_key(row[5]))) is not None:
                join(own_id, row[0])

    merged: dict[int, list[tuple[int, int, int]]] = {}
    for items in buckets.values():
        for item in items:
            merged.setdefault(representative(item[0]), []).append(item)
    for items in merged.values():
        root = result.roots[items[0][1]]
        # Richer text wins without classifying or hiding short posts. Stable
        # ties prefer the displayed publication, then the oldest stored copy.
        preferred = max(items, key=lambda item: (item[2], item[1] == root, -item[0]))[0]
        result.copies[preferred] = [item[0] for item in items]
        result.representatives.update({item[0]: preferred for item in items})
    return result


async def combine(session: AsyncSession, user_id: uuid.UUID, root_id: int, source_id: int) -> None:
    # Serialize grouping changes for one listener, including two simultaneous
    # opposite merges, so roots cannot form a cycle.
    subscriptions = list(
        await session.scalars(
            select(Subscription).where(Subscription.user_id == user_id).order_by(Subscription.id).with_for_update()
        )
    )
    by_feed = {s.feed_id: s for s in subscriptions}
    if root_id not in by_feed or source_id not in by_feed:
        raise LookupError("Both sources must be subscriptions in your library.")
    if root_id == source_id or by_feed[root_id].group_feed_id is not None:
        raise ValueError("Choose a separate publication from your library.")
    source = by_feed[source_id]
    if source.group_feed_id == root_id:
        return
    if source.group_feed_id is not None:
        raise ValueError("Separate this source from its current publication first.")
    for subscription in subscriptions:
        if subscription.feed_id == source_id or subscription.group_feed_id == source_id:
            subscription.group_feed_id = root_id
    await session.commit()


async def separate(session: AsyncSession, user_id: uuid.UUID, root_id: int, source_id: int) -> None:
    subscriptions = list(
        await session.scalars(
            select(Subscription).where(Subscription.user_id == user_id).order_by(Subscription.id).with_for_update()
        )
    )
    source = next((s for s in subscriptions if s.feed_id == source_id and s.group_feed_id == root_id), None)
    if source is None:
        raise LookupError("Source not found in this publication.")
    await preserve_states(session, user_id, root_id)
    source.group_feed_id = None
    await session.commit()


async def preserve_states(session: AsyncSession, user_id: uuid.UUID, root_id: int) -> None:
    """Separating sources keeps the state they shared while combined."""
    from audioreader import positions

    user = await session.get(User, user_id)
    if user is None:
        return
    group = await catalog(session, user_id)
    ids = [item_id for item_id, feed_id in group.episode_feeds.items() if group.roots[feed_id] == root_id]
    states = await positions.positions_for(session, user, ids)
    for item_id, state in states.items():
        row = await session.get(PlaybackPosition, (user_id, item_id))
        if row is None:
            row = PlaybackPosition(user_id=user_id, episode_id=item_id)
            session.add(row)
        row.position_seconds = state.position_seconds
        row.completed = state.completed
        row.dismissed = state.dismissed
        row.updated_at = state.updated_at


async def release_children(session: AsyncSession, user_id: uuid.UUID, root_id: int) -> None:
    """A sender removed outside Manage sources must not strand other feeds."""
    children = list(
        await session.scalars(
            select(Subscription).where(Subscription.user_id == user_id, Subscription.group_feed_id == root_id)
        )
    )
    if children:
        await preserve_states(session, user_id, root_id)
        for child in children:
            child.group_feed_id = None
        session.info.pop("feed_group_catalog", None)
