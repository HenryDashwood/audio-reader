"""Evaluate real clarification exchanges, preserving database and wire state across turns.

    uv run python -m evals.conversations --repeat 3 --json ../build/jev-evals/conversations.json

Only the model providers are live. Libraries, publishers and directory results
are synthetic. User replies and expected effects are fixed before the model runs.
"""

import argparse
import asyncio
import hashlib
import json
import os
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from dotenv import dotenv_values
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from audioreader.commands.conversation import ConversationFinished, converse
from audioreader.commands.intents import Action, Speaker, Turn
from audioreader.config import REPO_ROOT, settings
from audioreader.models import Base, Feed, PlaybackPosition, User
from audioreader.schemas import CommandRequest
from evals.cases import IN_OUR_TIME, MONEY_STUFF, REST_IS_POLITICS
from evals.compare_jev import Pacer, TracedOpenAI, token_cost
from evals.jev import JevClient
from evals.runner import subscribed_urls
from evals.world import build_world, seed, stub_world


@dataclass(frozen=True)
class Scenario:
    name: str
    request: str
    replies: tuple[str, ...]
    removed: str | None = None
    added: str | None = None
    speed: float | None = None
    labels: tuple[str, ...] = ()


SCENARIOS = (
    Scenario(
        "unsubscribe-short-name",
        "Unsubscribe from The Rest Is",
        ("Politics",),
        removed=REST_IS_POLITICS,
        labels=("History", "Politics"),
    ),
    Scenario(
        "unsubscribe-ordinal",
        "Unsubscribe from The Rest Is",
        ("the second one",),
        removed=REST_IS_POLITICS,
        labels=("History", "Politics"),
    ),
    Scenario(
        "unsubscribe-semantic-reply",
        "Unsubscribe from The Rest Is",
        ("the political one",),
        removed=REST_IS_POLITICS,
        labels=("History", "Politics"),
    ),
    Scenario(
        "yes-does-not-answer-either-or",
        "Unsubscribe from The Rest Is",
        ("yes", "Politics"),
        removed=REST_IS_POLITICS,
        labels=("History", "Politics"),
    ),
    Scenario(
        "neither-then-correction",
        "Unsubscribe from The Rest Is",
        ("neither", "In Our Time"),
        removed=IN_OUR_TIME,
        labels=("History", "Politics"),
    ),
    Scenario("cancel-choice", "Unsubscribe from The Rest Is", ("cancel",), labels=("History", "Politics")),
    Scenario(
        "change-subject",
        "Unsubscribe from The Rest Is",
        ("Actually set the speed to 1.5",),
        speed=1.5,
        labels=("History", "Politics"),
    ),
    Scenario(
        "newsletter-short-name",
        "Follow that newsletter",
        ("Matt Levine",),
        added=MONEY_STUFF,
        labels=("Matt Levine", "Benedict Evans"),
    ),
    Scenario(
        "compound-keeps-remaining-step",
        "Unsubscribe from The Rest Is and set playback speed to 1.5",
        ("Politics",),
        removed=REST_IS_POLITICS,
        speed=1.5,
        labels=("History", "Politics"),
    ),
)


async def snapshot(session, user):
    positions = list(await session.scalars(select(PlaybackPosition).where(PlaybackPosition.user_id == user.id)))
    feeds = list(await session.scalars(select(Feed).where(Feed.owner_user_id == user.id)))
    return (
        await subscribed_urls(session, user),
        sorted((p.episode_id, p.completed, p.dismissed, p.position_seconds) for p in positions),
        sorted((f.id, f.approval) for f in feeds),
    )


async def run_scenario(scenario, world, factory):
    engine = create_async_engine("sqlite+aiosqlite://")
    records, turns, errors, effects = [], [], [], []
    started = time.perf_counter()
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        async with async_sessionmaker(engine, expire_on_commit=False)() as session:
            user = User(display_name="Conversation evaluation")
            session.add(user)
            await session.commit()
            await seed(session, user, world)
            original = await snapshot(session, user)
            clarification_id = None
            for index, text in enumerate((scenario.request, *scenario.replies)):
                client = factory()
                # Round-trip precisely the public client fields. A spoken question
                # by itself cannot smuggle private model state into the next turn.
                request = CommandRequest.model_validate_json(
                    CommandRequest(
                        transcript=text,
                        turns=turns[-8:],
                        clarification_id=clarification_id,
                        timezone="Europe/London",
                        supports_compound_actions=True,
                    ).model_dump_json()
                )
                before = await snapshot(session, user)
                tick = time.perf_counter()
                result = None
                async for event in converse(
                    session,
                    client,
                    user=user,
                    turns=request.turns,
                    **request.model_dump(exclude={"request_id", "turns"}),
                ):
                    if isinstance(event, ConversationFinished):
                        result = event.result
                if result is None:
                    raise RuntimeError("No final result")
                after = await snapshot(session, user)
                effects.extend(result.actions or [result])
                records.append(
                    {
                        "said": text,
                        "spoken": result.spoken_response,
                        "status": result.status.value,
                        "action": result.action.value,
                        "seconds": time.perf_counter() - tick,
                        "clarification": result.clarification.model_dump(mode="json")
                        if result.clarification
                        else None,
                    }
                )
                if index < len(scenario.replies):
                    if not result.expects_reply or result.clarification is None:
                        errors.append(f"Turn {index + 1}: no answerable structured question")
                    if before != after or any(
                        item.action is not Action.UNKNOWN for item in (result.actions or [result])
                    ):
                        errors.append(f"Turn {index + 1}: acted before the ambiguity was resolved")
                if index == 0 and result.clarification:
                    labels = " ".join(choice.label for choice in result.clarification.choices)
                    if any(label.casefold() not in labels.casefold() for label in scenario.labels):
                        errors.append("Question did not offer the expected alternatives")
                turns.extend(
                    (Turn(speaker=Speaker.HER, text=text), Turn(speaker=Speaker.APP, text=result.spoken_response))
                )
                clarification_id = result.clarification.id if result.clarification else None
            final = await snapshot(session, user)
            removed, added = original[0] - final[0], final[0] - original[0]
            if removed != ({scenario.removed} if scenario.removed else set()):
                errors.append("Incorrect subscription removal")
            if added != ({scenario.added} if scenario.added else set()):
                errors.append("Incorrect subscription addition")
            speeds = [effect.speed for effect in effects if effect.action is Action.SET_SPEED]
            if speeds != ([scenario.speed] if scenario.speed is not None else []):
                errors.append("Incorrect speed effects")
            if any(effect.episode is not None for effect in effects):
                errors.append("Unexpected playback or filing")
            if final[1] != original[1]:
                errors.append("Unexpected persisted filing or progress change")
            if result is not None and result.expects_reply:
                errors.append("Still unresolved after the final answer")
    except Exception as exc:
        errors.append(f"Provider/harness error: {type(exc).__name__}: {exc}")
    finally:
        await engine.dispose()
    return {
        "scenario": scenario.name,
        "passed": not errors,
        "errors": errors,
        "turns": records,
        "seconds_including_fixture": time.perf_counter() - started,
        "command_seconds": sum(row["seconds"] for row in records),
        "spoken_words": sum(len(row["spoken"].split()) for row in records),
    }


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--modes", nargs="+", choices=("baseline", "hybrid"), default=["baseline", "hybrid"])
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    key = os.environ.get("JEV_API_KEY") or dotenv_values(REPO_ROOT / ".env").get("JEV_API_KEY")
    if "hybrid" in args.modes and not key:
        raise ValueError("JEV_API_KEY is required")
    pacer, world, rows = Pacer(1.8), build_world(), []
    metadata = {
        "started_at": datetime.now(UTC).isoformat(),
        "model": settings.openai_model,
        "repeat": args.repeat,
        "scope": "Synthetic libraries, live providers; excludes speech/device latency. Fixed scripted user replies.",
        "source_sha256": {
            str(p.relative_to(REPO_ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in (REPO_ROOT / "backend/src/audioreader/commands", REPO_ROOT / "backend/evals")
            for p in folder.glob("*.py")
        },
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)

    def save(complete=False):
        args.json.write_text(json.dumps({"metadata": metadata, "complete": complete, "runs": rows}, indent=2) + "\n")

    configured = settings.inbound_email_domain, settings.inbound_email_secret
    settings.inbound_email_domain, settings.inbound_email_secret = "magpieinbox.com", "eval"
    try:
        with stub_world(world):
            for repetition in range(args.repeat):
                for scenario in SCENARIOS:
                    for mode in args.modes:
                        baseline, jevs = TracedOpenAI(pacer), []

                        def factory(mode=mode, baseline=baseline, jevs=jevs):
                            if mode == "baseline":
                                return baseline
                            client = JevClient(api_key=key or "", fallback=baseline)
                            jevs.append(client)
                            return client

                        async with baseline.inner.connection():
                            result = await run_scenario(scenario, world, factory)
                        calls = baseline.calls + [call for client in jevs for call in client.calls]
                        result.update(
                            mode=mode,
                            repetition=repetition + 1,
                            calls=calls,
                            estimated_token_cost_usd=sum(token_cost(call) or 0 for call in calls),
                        )
                        result["command_seconds"] -= sum(call.get("benchmark_wait_seconds", 0) for call in calls)
                        rows.append(result)
                        save()
                        print(
                            f"{mode} {scenario.name}: {'PASS' if result['passed'] else result['errors']}", flush=True
                        )
    finally:
        settings.inbound_email_domain, settings.inbound_email_secret = configured
        save()
    save(complete=True)


if __name__ == "__main__":
    asyncio.run(main())
