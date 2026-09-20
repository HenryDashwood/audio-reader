"""Live, evaluation-only comparison of the conversation model and a Jev fast path.

    uv run python -m evals.compare_jev --repeat 3 --json ../build/jev-evals/results.json

Reads JEV_API_KEY from the root .env without printing it. Only synthetic data is
sent. App tools use the same isolated SQLite databases and network fixtures as
the existing corpus. Provider-hosted web search can still run and incur fees.
"""

import argparse
import asyncio
import hashlib
import json
import math
import os
import random
import statistics
import time
from datetime import UTC, date, datetime
from pathlib import Path

from dotenv import dotenv_values

from audioreader.config import REPO_ROOT, settings
from audioreader.llm.openai_responses import OpenAIResponsesClient, ResponseCompleted
from evals import cases as corpus
from evals.jev import MODEL, JevClient
from evals.runner import run_case
from evals.world import build_world, stub_world

# Public standard rates checked 2026-09-20. Estimates, not billing records.
PRICING = {
    "jev": {"input_per_million": 0.042, "output_per_million": 0},
    "gpt-5.6-luna": {
        "input_per_million": 0.2,
        "cached_per_million": 0.02,
        "cache_write_per_million": 0.25,
        "output_per_million": 1.2,
    },
}


class TracedOpenAI:
    """A fresh instance per case, with connection reuse across its tool rounds."""

    def __init__(self, pacer=None):
        self.inner = OpenAIResponsesClient(
            api_key=settings.openai_api_key,
            model=settings.openai_model,
            url=settings.openai_responses_url,
            reasoning_effort=settings.openai_reasoning_effort,
        )
        self.model = self.inner.model
        self.calls: list[dict] = []
        self.pacer = pacer

    async def stream(self, **kwargs):
        wait = await self.pacer.wait() if self.pacer else 0.0
        started = time.perf_counter()
        record = {"provider": "openai", "model": self.model, "benchmark_wait_seconds": wait}
        self.calls.append(record)
        try:
            async for event in self.inner.stream(**kwargs):
                if isinstance(event, ResponseCompleted):
                    body = event.response
                    record.update(
                        model=body.get("model", self.model),
                        usage=body.get("usage", {}),
                        tools=[
                            {key: item[key] for key in ("type", "name", "arguments", "action") if key in item}
                            for item in body.get("output", [])
                            if item.get("type") in {"function_call", "web_search_call"}
                        ],
                    )
                yield event
        except Exception as exc:
            record["error"] = type(exc).__name__
            record["rate_limited"] = "rate_limit" in str(exc) or "429" in str(exc)
            raise
        finally:
            record["seconds"] = time.perf_counter() - started


class Pacer:
    """Shared benchmark throttle, explicitly excluded from reported latency."""

    def __init__(self, interval):
        self.interval = interval
        self.lock = asyncio.Lock()
        self.next_start = 0.0

    async def wait(self):
        started = time.perf_counter()
        async with self.lock:
            await asyncio.sleep(max(0.0, self.next_start - time.perf_counter()))
            self.next_start = time.perf_counter() + self.interval
        return time.perf_counter() - started


def token_cost(call: dict, *, ignore_cache: bool = False) -> float | None:
    usage = call.get("usage")
    if usage is None:
        return None
    provider = "jev" if call["provider"] == "jev" else settings.openai_model
    rates = PRICING.get(provider)
    if rates is None:
        return None
    input_tokens = usage.get("input_tokens", 0)
    details = usage.get("input_tokens_details") or {}
    cached = details.get("cached_tokens", 0) if not ignore_cache else 0
    writes = details.get("cache_write_tokens", 0) if not ignore_cache else 0
    return (
        (input_tokens - cached - writes) * rates["input_per_million"]
        + cached * rates.get("cached_per_million", rates["input_per_million"])
        + writes * rates.get("cache_write_per_million", rates["input_per_million"])
        + usage.get("output_tokens", 0) * rates["output_per_million"]
    ) / 1_000_000


def percentile(values: list[float], quantile: float) -> float:
    """Nearest-rank percentile; keep small-sample p95 honest."""
    return sorted(values)[max(0, math.ceil(len(values) * quantile) - 1)]


def summarize(rows: list[dict]) -> dict:
    result = {}
    for mode in sorted({row["mode"] for row in rows}):
        selected = [row for row in rows if row["mode"] == mode]
        calls = [call for row in selected for call in row["calls"]]
        costs = [token_cost(call) for call in calls]
        seconds = [row["command_seconds"] for row in selected]
        model_seconds = [sum(call["seconds"] for call in row["calls"]) for row in selected]
        accepted = [row for row in selected if row["decision"].get("reason") == "accepted"]
        result[mode] = {
            "runs": len(selected),
            "grades": {
                grade: sum(row["grade"] == grade for row in selected) for grade in ("pass", "asked", "fail", "error")
            },
            "jev_accepted": len(accepted),
            "jev_accepted_nonpass": sum(row["grade"] != "pass" for row in accepted),
            "fallback_runs": sum(row["fallback"] for row in selected),
            "median_command_seconds": statistics.median(seconds),
            "p95_command_seconds": percentile(seconds, 0.95),
            "median_model_seconds": statistics.median(model_seconds),
            "p95_model_seconds": percentile(model_seconds, 0.95),
            "input_tokens": sum(call.get("usage", {}).get("input_tokens", 0) for call in calls),
            "cached_input_tokens": sum(
                (call.get("usage", {}).get("input_tokens_details") or {}).get("cached_tokens", 0) for call in calls
            ),
            "output_tokens": sum(call.get("usage", {}).get("output_tokens", 0) for call in calls),
            "known_token_cost_usd": sum(cost for cost in costs if cost is not None),
            "uncached_token_cost_usd": sum(token_cost(call, ignore_cache=True) or 0 for call in calls),
            "calls_with_unknown_cost": sum(cost is None for cost in costs),
            "web_search_calls": sum(
                tool["type"] == "web_search_call" for call in calls for tool in call.get("tools", [])
            ),
            "model_calls": len(calls),
        }
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--modes", nargs="+", choices=("baseline", "jev", "hybrid"), default=["baseline", "jev", "hybrid"]
    )
    parser.add_argument("--patterns", nargs="*", default=[])
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--threshold", type=float, default=0.9)
    parser.add_argument(
        "--openai-interval", type=float, default=1.8, help="Minimum seconds between baseline API calls."
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--json", type=Path, required=True)
    return parser.parse_args(argv)


async def main(argv=None):
    args = parse_args(argv)
    if args.repeat < 1 or args.concurrency < 1 or args.openai_interval < 0 or not 0 <= args.threshold <= 1:
        raise ValueError("Invalid repetition, concurrency or confidence threshold")
    values = dotenv_values(REPO_ROOT / ".env")
    key = os.environ.get("JEV_API_KEY") or values.get("JEV_API_KEY")
    if any(mode != "baseline" for mode in args.modes) and not key:
        raise ValueError("JEV_API_KEY is missing from the environment or root .env")
    if any(mode != "jev" for mode in args.modes) and not settings.openai_api_key:
        raise ValueError("The existing OpenAI API key is missing")
    cases = corpus.select(tuple(args.patterns))
    if not cases:
        raise ValueError("No matching cases")
    reference = date.today()
    world = build_world(reference)
    metadata = {
        "started_at": datetime.now(UTC).isoformat(),
        "reference_date": reference.isoformat(),
        "baseline_model": settings.openai_model,
        "baseline_reasoning": settings.openai_reasoning_effort,
        "jev_model": MODEL,
        "confidence_threshold": args.threshold,
        "candidate_limit": settings.command_candidate_limit,
        "search_limit": settings.command_search_limit,
        "repeat": args.repeat,
        "concurrency": args.concurrency,
        "openai_interval_seconds": args.openai_interval,
        "seed": args.seed,
        "source_sha256": {
            name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in ("jev.py", "compare_jev.py", "cases.py", "world.py", "runner.py")
        },
        "pricing": PRICING,
        "scope": "Synthetic corpus; real model calls; mocked directory, feeds and app effects. "
        "No speech/device timing.",
        "cost_note": "Token estimates include reported cached-input discounts; "
        "exclude web-search fees and unreported usage.",
    }
    rows: list[dict] = []
    args.json.parent.mkdir(parents=True, exist_ok=True)

    def save(complete=False):
        payload = {"metadata": metadata, "complete": complete, "summary": summarize(rows), "runs": rows}
        temporary = args.json.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n")
        temporary.replace(args.json)

    limiter = asyncio.Semaphore(args.concurrency)
    pacer = Pacer(args.openai_interval)

    async def one(case, mode, repetition):
        async with limiter:
            baseline = TracedOpenAI(pacer)
            jev = JevClient(
                api_key=key or "", fallback=baseline if mode == "hybrid" else None, threshold=args.threshold
            )
            client = baseline if mode == "baseline" else jev
            async with baseline.inner.connection():
                outcome = await run_case(case, world, client, pipeline="conversation")
            calls = baseline.calls if mode == "baseline" else jev.calls + baseline.calls
            row = {
                "case": case.id,
                "said": case.said,
                "tags": case.tags,
                "mode": mode,
                "repetition": repetition,
                "grade": outcome.grade.value,
                "detail": outcome.detail,
                "spoken": outcome.spoken,
                "command_seconds": outcome.command_seconds
                - sum(call.get("benchmark_wait_seconds", 0) for call in calls),
                "command_seconds_with_throttle": outcome.command_seconds,
                "total_seconds_with_fixture": outcome.seconds,
                "fallback": jev.delegated if mode != "baseline" else False,
                "decision": jev.decision if mode != "baseline" else {},
                "calls": calls,
            }
            rows.append(row)
            save()
            reason = row["decision"].get("reason", "")
            print(
                f"{mode:8} {outcome.grade.value:5} {row['command_seconds']:6.2f}s {case.id} [{repetition}] {reason}",
                flush=True,
            )

    jobs = [(case, mode, attempt + 1) for case in cases for mode in args.modes for attempt in range(args.repeat)]
    random.Random(args.seed).shuffle(jobs)
    configured = settings.inbound_email_domain, settings.inbound_email_secret
    settings.inbound_email_domain = settings.inbound_email_domain or "magpieinbox.com"
    settings.inbound_email_secret = settings.inbound_email_secret or "eval"
    try:
        with stub_world(world):
            await asyncio.gather(*(one(*job) for job in jobs))
    finally:
        settings.inbound_email_domain, settings.inbound_email_secret = configured
        save()
    save(complete=True)
    print(json.dumps(summarize(rows), indent=2))


if __name__ == "__main__":
    asyncio.run(main())
