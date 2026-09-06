import asyncio
import json
import uuid

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import AsyncAdaptedQueuePool

from audioreader.commands.receipts import recoverable_events
from audioreader.models import Base
from audioreader.schemas import CommandRequest


@pytest.fixture
async def session():
    # Concurrent receipt workers need separate transactions. The ordinary
    # single-connection SQLite fixture would let a reader roll a writer back.
    name = uuid.uuid4().hex
    engine = create_async_engine(
        f"sqlite+aiosqlite:///file:{name}?mode=memory&cache=shared&uri=true",
        poolclass=AsyncAdaptedQueuePool,
    )
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as value:
        yield value
    await engine.dispose()


async def test_retry_replays_result_without_repeating_action(session, user):
    calls = 0

    async def events(_session):
        nonlocal calls
        calls += 1
        yield b'{"type":"result","response":{"action":"subscribed","spoken_response":"Done"}}\n'

    request = CommandRequest(transcript="subscribe", request_id="request-one")
    first = [line async for line in recoverable_events(request, user.id, session, events)]
    second = [line async for line in recoverable_events(request, user.id, session, events)]
    assert first == second
    assert calls == 1


async def test_same_id_cannot_execute_different_request(session, user):
    async def events(_session):
        yield b'{"type":"result","response":{"action":"unknown","spoken_response":"Done"}}\n'

    first = CommandRequest(transcript="first", request_id="same-id")
    _ = [line async for line in recoverable_events(first, user.id, session, events)]
    other = CommandRequest(transcript="second", request_id="same-id")
    result = [line async for line in recoverable_events(other, user.id, session, events)]
    assert json.loads(result[-1])["type"] == "error"


async def test_disconnect_does_not_cancel_claimed_work(session, user):
    started, finish = asyncio.Event(), asyncio.Event()
    calls = 0

    async def events(_session):
        nonlocal calls
        calls += 1
        started.set()
        yield b'{"type":"assistant_delta","text":""}\n'
        await finish.wait()
        yield b'{"type":"result","response":{"action":"subscribed","spoken_response":"Done"}}\n'

    request = CommandRequest(transcript="subscribe", request_id="disconnect")
    stream = recoverable_events(request, user.id, session, events)
    await asyncio.wait_for(anext(stream), timeout=2)
    await stream.aclose()
    finish.set()

    async def collect():
        return [line async for line in recoverable_events(request, user.id, session, events)]

    result = await asyncio.wait_for(collect(), timeout=3)
    assert json.loads(result[-1])["type"] == "result"
    assert calls == 1


async def test_cancel_before_request_arrives_prevents_execution(session, user):
    from audioreader.commands.receipts import cancel_request

    await cancel_request(session, user.id, "cancel-first")
    called = False

    async def events(_session):
        nonlocal called
        called = True
        yield b'{"type":"result"}\n'

    request = CommandRequest(transcript="subscribe", request_id="cancel-first")
    result = [line async for line in recoverable_events(request, user.id, session, events)]
    assert not called
    assert "stopped" in json.loads(result[-1])["spoken_response"]


async def test_cancellation_cannot_erase_a_completed_receipt(session, user):
    from audioreader.commands.receipts import cancel_request

    async def events(_session):
        yield b'{"type":"result","response":{"action":"subscribed","spoken_response":"Done"}}\n'

    request = CommandRequest(transcript="subscribe", request_id="finished")
    first = [line async for line in recoverable_events(request, user.id, session, events)]
    await cancel_request(session, user.id, "finished")
    assert first == [line async for line in recoverable_events(request, user.id, session, events)]
