"""Keep a claimed request alive after disconnect, with a durable final result.

A process crash can leave a claim without a result. Such a claim is NEVER
re-executed: an external newsletter submission might already have succeeded.
"""

import asyncio
import hashlib
import json
import logging
import uuid
from collections.abc import AsyncGenerator, AsyncIterator, Callable
from contextvars import ContextVar
from weakref import WeakKeyDictionary

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from audioreader.models import VoiceCommandReceipt, utcnow
from audioreader.schemas import CommandRequest

_jobs: dict[tuple[uuid.UUID, str], asyncio.Task] = {}
_current: ContextVar[tuple[uuid.UUID, str] | None] = ContextVar("voice_request", default=None)
logger = logging.getLogger(__name__)


class CommandCancelled(Exception):
    pass


async def check_cancelled(session):
    key = _current.get()
    if key is not None:
        receipt = await session.get(VoiceCommandReceipt, key, populate_existing=True)
        if receipt is None or receipt.cancel_requested:
            raise CommandCancelled()


async def cancel_request(session, user_id, request_id):
    key = (user_id, request_id)
    receipt = await session.get(VoiceCommandReceipt, key)
    if receipt is not None and receipt.result_json is not None:
        return
    if receipt is None:
        receipt = VoiceCommandReceipt(user_id=user_id, request_id=request_id, fingerprint="cancelled")
        session.add(receipt)
    receipt.cancel_requested = True
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        receipt = await session.get(VoiceCommandReceipt, key)
        if receipt is not None:
            receipt.cancel_requested = True
            await session.commit()
    if task := _jobs.get(key):
        task.cancel()


# Keep short receipt transactions from contending with each other on SQLite.
# Cross-process exclusion still comes from the database's unique key.
_receipt_locks = WeakKeyDictionary()


def error_line(text: str) -> bytes:
    return (json.dumps({"type": "error", "spoken_response": text}) + "\n").encode()


async def recoverable_events(
    body: CommandRequest,
    user_id: uuid.UUID,
    session: AsyncSession,
    events: Callable[[AsyncSession], AsyncIterator[bytes]],
) -> AsyncGenerator[bytes]:
    assert body.request_id is not None
    key = (user_id, body.request_id)
    fingerprint = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
    maker = async_sessionmaker(session.bind, expire_on_commit=False)
    lock = _receipt_locks.setdefault(session.bind, asyncio.Lock())
    queue: asyncio.Queue[bytes | None] = asyncio.Queue(maxsize=256)
    receipt = VoiceCommandReceipt(user_id=user_id, request_id=body.request_id, fingerprint=fingerprint)
    async with lock, maker() as claim:
        claim.add(receipt)
        try:
            await claim.commit()
            claimed = True
        except IntegrityError:
            await claim.rollback()
            claimed = False
            receipt = await claim.get(VoiceCommandReceipt, key)
            if receipt is not None and receipt.cancel_requested and receipt.result_json is None:
                yield error_line("That request was stopped. Any changes already completed remain in your library.")
                return
            if receipt is None or receipt.fingerprint != fingerprint:
                yield error_line("That request identifier was already used for a different request.")
                return

    if claimed:

        async def work() -> None:
            token = _current.set(key)
            final = error_line(
                "I could not confirm the outcome. Please check your library before repeating the action."
            )
            try:
                async with maker() as worker:
                    async with asyncio.timeout(120):
                        async for line in events(worker):
                            envelope = json.loads(line)
                            if envelope.get("type") in {"result", "error"}:
                                final = line
                            # Slow or disconnected consumers must not block completion.
                            if not queue.full():
                                queue.put_nowait(line)
            except (CommandCancelled, asyncio.CancelledError):
                final = error_line("That request was stopped. Any changes already completed remain in your library.")
            except Exception as exc:
                logger.warning("Voice command failed: %s", type(exc).__name__)
                # The durable claim remains authoritative even if work partially
                # committed. Do not invite an automatic repeat of side effects.
                pass
            finally:
                _current.reset(token)
                async with lock, maker() as writer:
                    saved = await writer.get(VoiceCommandReceipt, key)
                    if saved is not None:
                        saved.result_json = final.decode()
                        await writer.commit()
                if not queue.full():
                    queue.put_nowait(None)

        task = asyncio.create_task(work())
        _jobs[key] = task
        task.add_done_callback(lambda _: _jobs.pop(key, None))

    # Duplicates on another worker can recover the stored outcome too. No
    # assumption about process-local locks or a single server replica.
    while True:
        final_line = None
        async with lock, maker() as reader:
            saved = await reader.get(VoiceCommandReceipt, key)
            if saved is None:
                final_line = error_line("That request is no longer available.")
            elif saved.result_json is not None:
                final_line = saved.result_json.encode()
            elif saved.cancel_requested:
                final_line = error_line(
                    "That request was stopped. Any changes already completed remain in your library."
                )
            else:
                created = saved.created_at
                if created.tzinfo is None:
                    created = created.replace(tzinfo=utcnow().tzinfo)
                if (utcnow() - created).total_seconds() > 180:
                    final_line = error_line(
                        "The earlier request was interrupted. Check your library before repeating it."
                    )
        if final_line is not None:
            yield final_line
            return
        try:
            line = await asyncio.wait_for(queue.get(), timeout=0.25)
            if line is not None and json.loads(line).get("type") == "assistant_delta":
                yield line
        except TimeoutError:
            pass
