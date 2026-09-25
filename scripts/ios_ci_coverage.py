#!/usr/bin/env python3
"""Whether main CI has already run the iOS tests on this commit's app sources.

The TestFlight workflow skips its own test run when this finds a completed,
successful "iOS tests" job on this commit or an ancestor and nothing that job
depends on has changed since. Anything it cannot prove, including an API error,
reports "not covered" so the tests run as before.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from deploy_backend import DeploymentError, github, output, validate_sha  # noqa: E402

IOS_JOB = "iOS tests"
# Must match the `ios` paths filter in .github/workflows/ci.yml, including the
# shared entries; a test keeps the two in step. A trailing slash is a directory.
IOS_TEST_INPUTS = (
    ".github/workflows/ci.yml",
    "Makefile",
    "ios/",
    "app-store/",
    "scripts/ios-dev.sh",
    "scripts/prepare-ios-simulators.sh",
)
# GitHub's compare API lists at most 300 files; beyond that the list is partial.
COMPARE_FILE_LIMIT = 300


class NotCovered(Exception):
    pass


def affects_ios_tests(path):
    return any(path.startswith(entry) if entry.endswith("/") else path == entry for entry in IOS_TEST_INPUTS)


def ios_job(run):
    attempt = run.get("run_attempt", 1)
    jobs = github(f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100")["jobs"]
    return next((job for job in jobs if job["name"] == IOS_JOB), None)


def tested_ancestor(sha):
    """The newest main CI run on an ancestor of `sha` whose iOS tests actually ran."""
    runs = github("actions/workflows/ci.yml/runs?branch=main&event=push&per_page=100")["workflow_runs"]
    # Newest first; a job skipped by the path filter says nothing either way.
    for run in sorted(runs, key=lambda run: run["id"], reverse=True):
        if run.get("head_branch") != "main" or run.get("event") != "push":
            continue
        job = ios_job(run)
        if job is None or job.get("conclusion") == "skipped":
            continue
        comparison = github(f"compare/{run['head_sha']}...{sha}")
        if comparison.get("status") not in {"ahead", "identical"}:
            # A later main commit, or one from a rewritten history.
            continue
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            raise NotCovered(f"the latest iOS test run on an ancestor ({run['html_url']}) did not pass")
        return run, comparison
    raise NotCovered("no successful iOS test run found on an ancestor in recent main CI")


def check(sha):
    validate_sha(sha)
    run, comparison = tested_ancestor(sha)
    files = comparison.get("files") or []
    if len(files) >= COMPARE_FILE_LIMIT:
        raise NotCovered(f"too many files changed since {run['head_sha']} to check them all")
    changed = sorted(
        path
        for file in files
        for path in (file.get("filename"), file.get("previous_filename"))
        if path and affects_ios_tests(path)
    )
    if changed:
        raise NotCovered(f"iOS test inputs changed since {run['head_sha']}: " + ", ".join(changed))
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    try:
        run = check(args.sha)
    except (NotCovered, DeploymentError) as reason:
        print(f"Running the iOS tests: {reason}")
        output("covered", "false")
        return 0
    print(f"Skipping the iOS tests: they passed on {run['head_sha']} in {run['html_url']}")
    output("covered", "true")
    output("tested_sha", run["head_sha"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
