"""Command line for the eval corpus.

    uv run python -m evals                       # everything, current settings
    uv run python -m evals play back-catalogue   # only cases matching those
    uv run python -m evals --model deepseek/deepseek-v4-flash --repeat 3
    uv run python -m evals --candidates 200      # move the cost dial and see

Costs money: every case is at least one real model call.
"""

import argparse
import asyncio
import json
import logging
import sys
from datetime import date

from audioreader.commands.intents import Speaker
from audioreader.config import settings
from audioreader.llm.provider import build_llm_client
from audioreader.settings_types import LLMProvider
from evals import cases as corpus
from evals.grading import Grade
from evals.runner import Report, Run, run
from evals.world import build_world

COLOURS = {
    Grade.PASS: "\033[32m",
    Grade.ASKED: "\033[33m",
    Grade.FAIL: "\033[31m",
    Grade.ERROR: "\033[35m",
}
RESET = "\033[0m"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="evals", description=__doc__)
    parser.add_argument(
        "patterns",
        nargs="*",
        help="Only run cases whose id or tags contain one of these substrings.",
    )
    parser.add_argument("--model", help="Override the model id for this run.")
    parser.add_argument(
        "--provider",
        choices=[provider.value for provider in LLMProvider],
        help="Override the provider for this run.",
    )
    parser.add_argument(
        "--candidates",
        type=int,
        help=f"Override how many episodes the model chooses between (default {settings.command_candidate_limit}).",
    )
    parser.add_argument(
        "--search",
        type=int,
        metavar="N",
        help="Override how many older episodes matching her words are added to that "
        f"window (default {settings.command_search_limit}; 0 is recency only).",
    )
    parser.add_argument(
        "--reasoning",
        action=argparse.BooleanOptionalAction,
        help="Override reasoning for providers that expose it.",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="Run each case this many times. Models are not deterministic and "
        "a request that fails one time in three is a failing request.",
    )
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument(
        "--reference-date",
        type=date.fromisoformat,
        help="Pin the world's dates (YYYY-MM-DD) instead of counting back from today.",
    )
    parser.add_argument("--json", metavar="PATH", help="Also write the results as JSON.")
    parser.add_argument("--quiet", action="store_true", help="Summary only.")
    return parser.parse_args(argv)


def apply_overrides(args: argparse.Namespace) -> None:
    """Settings are a process-wide singleton, and the clients read them when
    they are built — so overriding here is enough, and has to happen first."""
    if args.provider:
        settings.llm_provider = LLMProvider(args.provider)
    if args.model:
        if settings.llm_provider is LLMProvider.OPENROUTER:
            settings.openrouter_model = args.model
        else:
            settings.llm_model = args.model
    if args.candidates is not None:
        settings.command_candidate_limit = args.candidates
    if args.search is not None:
        settings.command_search_limit = args.search
    if args.reasoning is not None:
        settings.openrouter_reasoning = args.reasoning


def line(run_: Run, colour: bool) -> str:
    tint, reset = (COLOURS[run_.grade], RESET) if colour else ("", "")
    return (
        f"{tint}{run_.grade.value.upper():<5}{reset} {run_.case.id:<32} "
        f"{run_.seconds:5.1f}s {run_.llm_calls}×  {run_.detail}"
    )


def print_report(report: Report, cases: tuple[corpus.Case, ...], colour: bool) -> None:
    counts = report.counts
    print()
    print(
        f"  model {report.model}   candidates {report.candidate_limit}+{report.search_limit}"
        f"   repeat {report.repeat}   {len(cases)} cases"
    )
    print(
        f"  {counts[Grade.PASS]} pass   {counts[Grade.ASKED]} asked   "
        f"{counts[Grade.FAIL]} fail   {counts[Grade.ERROR]} error"
        f"   ({report.wall_seconds:.0f}s wall, {report.llm_calls} model calls)"
    )

    unresolved = [case for case in cases if report.worst(case) in (Grade.FAIL, Grade.ERROR)]
    if not unresolved:
        return
    print("\n  What is failing, and why it matters:\n")
    for case in unresolved:
        runs = [run_ for run_ in report.runs if run_.case.id == case.id]
        tally = "".join(run_.grade.value[0].upper() for run_ in runs)
        print(f"  {case.id}  [{tally}]")
        # The earlier lines first: "the one about Agincourt" on its own reads
        # like nonsense, and the exchange is what makes the failure legible.
        for turn in case.context:
            who = "she" if turn.speaker is Speaker.HER else "app"
            print(f'    {who}:  "{turn.text}"')
        print(f'    said: "{case.said}"')
        for run_ in runs:
            if run_.grade in (Grade.FAIL, Grade.ERROR):
                print(f"    got:  {run_.detail}")
                break
        print(f"    why:  {case.why}")
        print()


def as_json(report: Report) -> str:
    return json.dumps(
        {
            "model": report.model,
            "candidate_limit": report.candidate_limit,
            "search_limit": report.search_limit,
            "repeat": report.repeat,
            "wall_seconds": round(report.wall_seconds, 2),
            "llm_calls": report.llm_calls,
            "counts": {grade.value: report.counts[grade] for grade in Grade},
            "runs": [
                {
                    "case": run_.case.id,
                    "said": run_.case.said,
                    "tags": list(run_.case.tags),
                    "grade": run_.grade.value,
                    "detail": run_.detail,
                    "spoken": run_.spoken,
                    "seconds": round(run_.seconds, 2),
                    "llm_calls": run_.llm_calls,
                }
                for run_ in report.runs
            ],
        },
        indent=2,
    )


async def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.WARNING, format="  … %(message)s")
    args = parse_args(argv)
    apply_overrides(args)

    selected = corpus.select(tuple(args.patterns))
    if not selected:
        print(f"No cases match {args.patterns}", file=sys.stderr)
        return 2

    world = build_world(args.reference_date)
    client = build_llm_client()
    colour = sys.stdout.isatty()

    def show(run_: Run) -> None:
        if not args.quiet:
            print(line(run_, colour))

    report = await run(
        selected,
        world,
        client,
        repeat=args.repeat,
        concurrency=args.concurrency,
        on_result=show,
    )
    print_report(report, selected, colour)

    if args.json:
        with open(args.json, "w") as handle:
            handle.write(as_json(report))
        print(f"  written to {args.json}")

    # Non-zero when something is wrong, so this can gate a release later. A
    # question is not a pass, but it is not a broken build either.
    counts = report.counts
    return 1 if counts[Grade.FAIL] or counts[Grade.ERROR] else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
