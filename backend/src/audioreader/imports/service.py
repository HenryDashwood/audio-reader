"""Durable, account-scoped reviews and a single paced deployment-wide worker."""

import asyncio
import hashlib
import json
import logging
import math
import uuid
from datetime import timedelta

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from audioreader.feeds import service as feeds
from audioreader.feeds.discovery import FeedDiscoveryError
from audioreader.feeds.fetcher import FeedFetchError, FeedRateLimitedError
from audioreader.feeds.parser import FeedParseError
from audioreader.imports.opml import Preview
from audioreader.models import (
    Feed,
    FeedAlias,
    Subscription,
    User,
    utcnow,
)
from audioreader.models import (
    SubscriptionImport as Job,
)
from audioreader.models import (
    SubscriptionImportItem as Item,
)
from audioreader.models import (
    SubscriptionImportLease as Lease,
)

ACTIVE = ("queued", "running")
PENDING = ("pending", "processing")
logger = logging.getLogger(__name__)


def problem(message: str, status: int = 409):
    return HTTPException(status_code=status, detail={"spoken_response": message})


class ItemRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    title: str
    host: str
    status: str
    message: str | None
    selected: bool
    retryable: bool
    feed_id: int | None


class JobRead(BaseModel):
    id: str
    status: str
    duplicates: int
    folders: bool
    total: int
    finished: int
    added: int
    already_following: int
    failed: int
    not_imported: int
    items: list[ItemRead]


class Start(BaseModel):
    request_id: str = Field(min_length=1, max_length=128, pattern=r"^[a-zA-Z0-9_-]+$")
    entry_ids: list[int] = Field(min_length=1, max_length=2_000)
    public_feeds_confirmed: bool = False


class Retry(BaseModel):
    request_id: str = Field(min_length=1, max_length=128, pattern=r"^[a-zA-Z0-9_-]+$")


async def items(session: AsyncSession, job_id: str) -> list[Item]:
    return list(await session.scalars(select(Item).where(Item.job_id == job_id).order_by(Item.ordinal)))


async def owned(session: AsyncSession, user: User, job_id: str) -> Job:
    job = await session.scalar(select(Job).where(Job.id == job_id, Job.user_id == user.id, Job.expires_at > utcnow()))
    if job is None:
        raise problem("This import has expired or isn't available. Choose your file again.", 404)
    return job


async def read(session: AsyncSession, job: Job) -> JobRead:
    rows = await items(session, job.id)
    selected = [row for row in rows if row.selected]
    return JobRead(
        id=job.id,
        status=job.status,
        duplicates=job.duplicates,
        folders=job.folders,
        total=len(selected),
        finished=sum(row.status not in PENDING for row in selected),
        added=sum(row.status == "added" for row in selected),
        already_following=sum(row.status == "already_following" for row in selected),
        failed=sum(row.status == "failed" for row in selected),
        not_imported=sum(row.status == "stopped" for row in selected),
        items=[ItemRead.model_validate(row) for row in rows],
    )


async def current(session: AsyncSession, user: User) -> Job | None:
    return await session.scalar(
        select(Job)
        .where(Job.user_id == user.id, Job.expires_at > utcnow())
        .order_by(Job.active_user.is_not(None).desc(), Job.created_at.desc())
        .limit(1)
    )


async def preview(session: AsyncSession, user: User, parsed: Preview) -> Job:
    active = await session.scalar(select(Job).where(Job.active_user == str(user.id)))
    if active:
        raise problem("An import is already running. Open it before starting another.")
    # Bound abandoned reviews, including their private URLs. Explicit deletes also
    # work with SQLite test connections that don't enable foreign-key cascades.
    drafts = select(Job.id).where(Job.user_id == user.id, Job.status == "draft")
    await session.execute(delete(Item).where(Item.job_id.in_(drafts)))
    await session.execute(delete(Job).where(Job.user_id == user.id, Job.status == "draft"))
    job = Job(
        user_id=user.id,
        expires_at=utcnow() + timedelta(hours=24),
        duplicates=parsed.duplicates,
        folders=parsed.folders,
    )
    session.add(job)
    await session.flush()
    urls = set(
        await session.scalars(
            select(Feed.url).join(Subscription, Subscription.feed_id == Feed.id).where(Subscription.user_id == user.id)
        )
    )
    urls.update(
        await session.scalars(
            select(FeedAlias.url)
            .join(Subscription, Subscription.feed_id == FeedAlias.feed_id)
            .where(Subscription.user_id == user.id)
        )
    )
    for ordinal, entry in enumerate(parsed.entries):
        session.add(
            Item(
                job_id=job.id,
                ordinal=ordinal,
                title=entry.title,
                host=entry.host,
                url=entry.url,
                status="already_following" if entry.url in urls else entry.status,
                message=entry.message,
            )
        )
    await session.commit()
    return job


async def start(session: AsyncSession, user: User, job: Job, body: Start) -> Job:
    if not body.public_feeds_confirmed:
        raise problem("Confirm that the selected feeds are public. Paid or private feeds aren't supported yet.", 422)
    chosen = set(body.entry_ids)
    fingerprint = hashlib.sha256(json.dumps(sorted(chosen)).encode()).hexdigest()
    if job.status != "draft":
        if job.request_id == body.request_id and job.fingerprint == fingerprint:
            return job
        raise problem("This import has already been started. Open its current progress.")
    rows = await items(session, job.id)
    valid = {row.id for row in rows if row.status == "ready"}
    if not chosen <= valid:
        raise problem("The selection has changed. Review your file again.", 422)
    try:
        claimed = await session.execute(
            update(Job)
            .where(Job.id == job.id, Job.status == "draft")
            .returning(Job.id)
            .values(
                status="queued",
                active_user=str(user.id),
                request_id=body.request_id,
                fingerprint=fingerprint,
                updated_at=utcnow(),
                expires_at=utcnow() + timedelta(days=7),
            )
        )
        if claimed.scalar_one_or_none() is None:
            raise problem("This import has changed. Reload its progress.")
        for row in rows:
            row.selected = row.id in chosen
            if row.selected:
                row.status = "pending"
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise problem("An import or request with this identifier already exists. Open your current import.") from exc
    await session.refresh(job)
    return job


async def stop(session: AsyncSession, job: Job) -> Job:
    # Taking the job's write lock serializes this with final subscription commits.
    await session.execute(
        update(Job)
        .where(Job.id == job.id, Job.status.in_(ACTIVE))
        .values(status="stopped", active_user=None, updated_at=utcnow())
    )
    await session.execute(
        update(Item).where(Item.job_id == job.id, Item.status.in_(PENDING)).values(status="stopped", message=None)
    )
    await session.commit()
    await session.refresh(job)
    return job


async def retry(session: AsyncSession, user: User, job: Job, body: Retry) -> Job:
    existing = await session.scalar(select(Job).where(Job.user_id == user.id, Job.request_id == body.request_id))
    if existing:
        if existing.retry_of != job.id:
            raise problem("This request identifier was already used for another import.")
        return existing
    if job.status not in {"completed", "stopped"}:
        raise problem("Wait for this import to finish before retrying.")
    failed = [row for row in await items(session, job.id) if row.status == "failed" and row.retryable]
    if not failed:
        raise problem("There are no failed subscriptions available to retry.", 422)
    new = Job(
        user_id=user.id,
        active_user=str(user.id),
        status="queued",
        request_id=body.request_id,
        retry_of=job.id,
        expires_at=utcnow() + timedelta(days=7),
    )
    try:
        session.add(new)
        await session.flush()
        for row in failed:
            session.add(
                Item(
                    job_id=new.id,
                    ordinal=row.ordinal,
                    title=row.title,
                    host=row.host,
                    url=row.url,
                    status="pending",
                    selected=True,
                    next_attempt_at=row.next_attempt_at,
                )
            )
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise problem("An import is already running. Open its progress.") from exc
    return new


async def claim_lease(session: AsyncSession) -> str | None:
    insert = pg_insert if session.get_bind().dialect.name == "postgresql" else sqlite_insert
    await session.execute(insert(Lease).values(id=1, token="", until=utcnow()).on_conflict_do_nothing())
    token = str(uuid.uuid4())
    result = await session.execute(
        update(Lease)
        .returning(Lease.id)
        .where(Lease.id == 1, Lease.until <= utcnow())
        .values(token=token, until=utcnow() + timedelta(seconds=120))
    )
    await session.commit()
    return token if result.scalar_one_or_none() is not None else None


async def cleanup(session: AsyncSession):
    expired = select(Job.id).where(Job.expires_at <= utcnow())
    await session.execute(delete(Item).where(Item.job_id.in_(expired)))
    await session.execute(delete(Job).where(Job.expires_at <= utcnow()))
    await session.commit()


async def process_one(maker: async_sessionmaker[AsyncSession]) -> bool:
    """At most one publisher request chain globally; leases recover process death.

    Preparation may commit catalogue rows. Following and the terminal receipt
    commit together only after checking both the global fence and job state.
    """
    async with maker() as session:
        token = await claim_lease(session)
        if token is None:
            return False
        cooldown = 2.0
        try:
            await cleanup(session)
            row = await session.scalar(
                select(Item)
                .join(Job)
                .where(Job.status.in_(ACTIVE), Item.status.in_(PENDING), Item.next_attempt_at <= utcnow())
                .order_by(Job.updated_at, Item.ordinal)
                .limit(1)
            )
            if row is None:
                return False
            item_id, job_id, url = row.id, row.job_id, row.url
            row.status = "processing"
            row.attempts += 1
            await session.execute(
                update(Job)
                .where(Job.id == job_id, Job.status.in_(ACTIVE))
                .values(status="running", updated_at=utcnow())
            )
            await session.commit()
            feed_id = None
            error = None
            retryable = False
            try:
                if url is None:
                    raise ValueError("missing URL")
                async with asyncio.timeout(60):
                    feed = await feeds.ensure_feed(session, url)
                    feed_id = feed.id
            except FeedRateLimitedError as exc:
                error, retryable = "The publisher asked us to wait. Try again later.", True
                delay = exc.retry_after_seconds or 60.0
                if not math.isfinite(delay) or delay > 86_400:
                    # Untrusted hints must not overflow timestamps or freeze all
                    # imports indefinitely. Do not retry this item automatically.
                    error, retryable = "The publisher is unavailable for an extended period. Import it later.", False
                else:
                    cooldown = max(2.0, delay)
            except (FeedParseError, FeedDiscoveryError):
                error = "No supported feed was found at this address."
            except (FeedFetchError, TimeoutError):
                error, retryable = "The publisher is temporarily unavailable.", True
            except IntegrityError:
                error, retryable = "This subscription changed while importing. Try again.", True
            except Exception as exc:
                # No exception message: it may contain a private URL or file data.
                logger.warning("import preparation failed (%s)", type(exc).__name__)
                error, retryable = "This subscription could not be imported. Try again.", True
            await session.rollback()
            fence = await session.execute(
                update(Lease)
                .returning(Lease.id)
                .where(Lease.id == 1, Lease.token == token, Lease.until > utcnow())
                .values(token=token)
            )
            if fence.scalar_one_or_none() is None:
                await session.rollback()
                return False
            live = await session.execute(
                update(Job)
                .where(Job.id == job_id, Job.status.in_(ACTIVE))
                .values(updated_at=utcnow())
                .returning(Job.id)
            )
            if live.scalar_one_or_none() is None:
                await session.rollback()
                return False
            row = await session.get(Item, item_id, populate_existing=True)
            job = await session.get(Job, job_id, populate_existing=True)
            if row is None or job is None:
                await session.rollback()
                return False
            if error:
                row.message, row.retryable = error, retryable
                row.next_attempt_at = utcnow() + timedelta(seconds=max(cooldown, 30))
                row.status = "pending" if retryable and row.attempts < 3 else "failed"
            else:
                user = await session.get(User, job.user_id)
                feed = await session.get(Feed, feed_id)
                if user is None or feed is None:
                    await session.rollback()
                    return False
                try:
                    async with session.begin_nested():
                        added = await feeds.follow_prepared_feed(session, feed, user)
                        await session.flush()
                except IntegrityError:
                    # A normal subscribe may win the same unique constraint.
                    added = False
                    if not await feeds.is_subscribed(session, feed.id, user):
                        raise
                row.status = "added" if added else "already_following"
                row.feed_id, row.message, row.retryable = feed.id, None, False
            await session.flush()
            pending = await session.scalar(
                select(Item.id).where(Item.job_id == job_id, Item.status.in_(PENDING)).limit(1)
            )
            if pending is None:
                job.status, job.active_user = "completed", None
                job.expires_at = utcnow() + timedelta(days=7)
            await session.commit()
            return True
        finally:
            await session.rollback()
            await session.execute(
                update(Lease)
                .returning(Lease.id)
                .where(Lease.id == 1, Lease.token == token)
                .values(until=utcnow() + timedelta(seconds=cooldown))
            )
            await session.commit()


async def run(maker: async_sessionmaker[AsyncSession]):
    while True:
        try:
            await process_one(maker)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("import worker will recover (%s)", type(exc).__name__)
        await asyncio.sleep(2)
