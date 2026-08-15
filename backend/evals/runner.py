"""Run the corpus against a real model and report what it did.

One in-memory database per run of a case, one shared set of network stubs,
and the real `commands.service.interpret` in between — so what is measured is
the pipeline she actually talks to, not the model in isolation. The only thing
reaching the internet is the model itself.
"""

import asyncio
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from audioreader.commands import service
from audioreader.config import settings
from audioreader.llm.client import LLMClient, LLMError
from audioreader.models import Base, Feed, Subscription, User
from evals.cases import Case
from evals.grading import Grade, Observed, grade
from evals.world import Show, seed, stub_world


class MeteredClient:
    """Wraps a provider client to count turns and time them.

    Cost per command is a design constraint here — the candidate list is the
    main dial — so a run that improves accuracy by asking the model three
    times should have to say so.
    """

    def __init__(self, inner: LLMClient):
        self.inner = inner
        self.calls = 0
        self.seconds = 0.0

    async def decide(self, *, system: str, user: str, output_model: type[BaseModel]) -> dict[str, Any]:
        self.calls += 1
        started = time.monotonic()
        try:
            return await self.inner.decide(system=system, user=user, output_model=output_model)
        finally:
            self.seconds += time.monotonic() - started


@dataclass
class Run:
    """One case, run once."""

    case: Case
    grade: Grade
    detail: str
    seconds: float
    llm_calls: int
    spoken: str = ""


@dataclass
class Report:
    model: str
    candidate_limit: int
    search_limit: int
    repeat: int
    runs: list[Run] = field(default_factory=list)
    wall_seconds: float = 0.0

    @property
    def counts(self) -> Counter:
        return Counter(run.grade for run in self.runs)

    @property
    def llm_calls(self) -> int:
        return sum(run.llm_calls for run in self.runs)

    def worst(self, case: Case) -> Grade:
        grades = [run.grade for run in self.runs if run.case.id == case.id]
        for candidate in (Grade.ERROR, Grade.FAIL, Grade.ASKED, Grade.PASS):
            if candidate in grades:
                return candidate
        return Grade.PASS


async def run_case(case: Case, world: tuple[Show, ...], client: LLMClient) -> Run:
    """One case against a database of its own, so nothing leaks between cases."""
    engine = create_async_engine("sqlite+aiosqlite://")
    metered = MeteredClient(client)
    started = time.monotonic()
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        maker = async_sessionmaker(engine, expire_on_commit=False)
        async with maker() as session:
            user = User(display_name="Eval")
            session.add(user)
            await session.commit()
            await seed(session, user, world)

            before = await subscribed_urls(session, user)
            try:
                result = await service.interpret(
                    session, metered, transcript=case.said, user=user, discovery_llm=metered
                )
            except LLMError as exc:
                return Run(
                    case=case,
                    grade=Grade.ERROR,
                    detail=f"{type(exc).__name__}: {exc}",
                    seconds=time.monotonic() - started,
                    llm_calls=metered.calls,
                )
            after = await subscribed_urls(session, user)

        observed = Observed.of(result, before, after)
        verdict, detail = grade(case, observed)
        return Run(
            case=case,
            grade=verdict,
            detail=detail,
            seconds=time.monotonic() - started,
            llm_calls=metered.calls,
            spoken=observed.spoken,
        )
    finally:
        await engine.dispose()


async def subscribed_urls(session, user: User) -> frozenset[str]:
    urls = await session.scalars(
        select(Feed.url).join(Subscription, Subscription.feed_id == Feed.id).where(Subscription.user_id == user.id)
    )
    return frozenset(urls)


async def run(
    cases: tuple[Case, ...],
    world: tuple[Show, ...],
    client: LLMClient,
    *,
    repeat: int = 1,
    concurrency: int = 4,
    on_result=None,
) -> Report:
    report = Report(
        model=getattr(client, "model", type(client).__name__),
        candidate_limit=settings.command_candidate_limit,
        search_limit=settings.command_search_limit,
        repeat=repeat,
    )
    limiter = asyncio.Semaphore(concurrency)

    async def one(case: Case) -> Run:
        async with limiter:
            result = await run_case(case, world, client)
        if on_result:
            on_result(result)
        return result

    started = time.monotonic()
    # One flat list of (case, attempt) pairs, so repeats of a slow case
    # overlap with other cases rather than queueing behind each other.
    with stub_world(world):
        report.runs = list(await asyncio.gather(*(one(case) for _ in range(repeat) for case in cases)))
    report.wall_seconds = time.monotonic() - started
    order = {case.id: index for index, case in enumerate(cases)}
    report.runs.sort(key=lambda run: order[run.case.id])
    return report
