#!/usr/bin/env python3
"""Exact-commit Railway deployments, driven by the repository's GitHub workflows.

Uses environment-scoped project tokens, never an account-wide Railway token.
No mutation is retried: on an ambiguous response, inspect Railway before retrying.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "deploy/railway.json").read_text())
RAILWAY_API = "https://backboard.railway.com/graphql/v2"
REQUIRED_CI_JOBS = {
    "Backend checks",
    "iOS tests",
    "Released iOS client compatibility",
    "Deploy backend to staging",
}
PENDING = {"INITIALIZING", "QUEUED", "WAITING", "BUILDING", "DEPLOYING"}
DEPLOYMENT_QUERY = """
query($id: String!) {
  deployment(id: $id) {
    id projectId environmentId serviceId status deploymentStopped meta
  }
}
"""


class DeploymentError(RuntimeError):
    pass


def request_json(url, *, headers, data=None):
    request = urllib.request.Request(url, headers=headers, data=data)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError) as error:
        # Avoid printing request headers, response bodies or tokens.
        raise DeploymentError(f"Request to {request.host} failed: {type(error).__name__}") from None


def railway(query, variables):
    token = os.environ.get("RAILWAY_TOKEN")
    if not token:
        raise DeploymentError("RAILWAY_TOKEN must be an environment-scoped project token")
    result = request_json(
        RAILWAY_API,
        headers={"Project-Access-Token": token, "Content-Type": "application/json"},
        data=json.dumps({"query": query, "variables": variables}).encode(),
    )
    if result.get("errors") or not result.get("data"):
        raise DeploymentError("Railway rejected the request; inspect the scoped deployment in Railway")
    return result["data"]


def github(path):
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise DeploymentError("GH_TOKEN is required to verify the commit's CI result")
    return request_json(
        f"https://api.github.com/repos/{CONFIG['repository']}/{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )


def validate_sha(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise DeploymentError("A full, lowercase 40-character commit SHA is required")
    return sha


def check_scope(deployment, environment, sha=None):
    expected = {
        "projectId": CONFIG["project_id"],
        "serviceId": CONFIG["service_id"],
        "environmentId": CONFIG["environments"][environment]["id"],
    }
    if any(deployment.get(key) != value for key, value in expected.items()):
        raise DeploymentError("Deployment belongs to a different project, service or environment")
    actual_sha = (deployment.get("meta") or {}).get("commitHash")
    if sha is not None and actual_sha != sha:
        raise DeploymentError("Railway deployment commit differs from the requested commit")


def verify_ci(sha):
    validate_sha(sha)
    comparison = github(f"compare/{sha}...main")
    if comparison.get("status") not in {"ahead", "identical"}:
        raise DeploymentError("The staged commit is not an ancestor of main")
    runs = github(f"actions/workflows/ci.yml/runs?head_sha={sha}&event=push&per_page=100")["workflow_runs"]
    matching = [
        run
        for run in runs
        if run.get("head_sha") == sha and run.get("head_branch") == "main" and run.get("event") == "push"
    ]
    # Fail closed if the most recent run/re-run has failed or is still running.
    latest = max(matching, key=lambda run: (run["id"], run.get("run_attempt", 1)), default=None)
    if latest is None or latest.get("conclusion") != "success" or latest.get("status") != "completed":
        raise DeploymentError("The staged commit must have a completed, successful main CI run")
    jobs = github(f"actions/runs/{latest['id']}/attempts/{latest.get('run_attempt', 1)}/jobs?per_page=100")["jobs"]
    passed = {job["name"] for job in jobs if job.get("conclusion") == "success"}
    if missing := REQUIRED_CI_JOBS - passed:
        raise DeploymentError("The commit has not passed the release gates: " + ", ".join(sorted(missing)))


def inspect_staging(deployment_id):
    if not re.fullmatch(r"[0-9a-f-]{36}", deployment_id):
        raise DeploymentError("Enter the staging deployment's UUID, not a branch name")
    deployment = railway(DEPLOYMENT_QUERY, {"id": deployment_id})["deployment"]
    check_scope(deployment, "staging")
    if deployment["status"] != "SUCCESS" or deployment["deploymentStopped"]:
        raise DeploymentError("The chosen staging deployment is not running successfully; restage it first")
    sha = validate_sha((deployment.get("meta") or {}).get("commitHash", ""))
    verify_ci(sha)
    output("sha", sha)
    output("staging_deployment_id", deployment_id)
    print(f"Verified staging deployment {deployment_id} at {sha}")
    return sha


def output(key, value):
    if path := os.environ.get("GITHUB_OUTPUT"):
        with Path(path).open("a") as handle:
            handle.write(f"{key}={value}\n")


def smoke_check(environment):
    url = CONFIG["environments"][environment]["url"]
    if request_json(url + "/health", headers={}) != {"status": "ok"}:
        raise DeploymentError("Backend health check returned an unexpected response")
    # Verify that deployment configuration has not accidentally bypassed auth.
    try:
        with urllib.request.urlopen(url + "/me", timeout=30):
            raise DeploymentError("Unauthenticated /me unexpectedly succeeded")
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise DeploymentError(f"Unauthenticated /me returned {error.code}, expected 401") from None


def deploy(environment, sha, *, timeout=1200):
    validate_sha(sha)
    deployment_id = railway(
        """
        mutation($environment: String!, $service: String!, $sha: String!) {
          serviceInstanceDeployV2(environmentId: $environment, serviceId: $service, commitSha: $sha)
        }
    """,
        {"environment": CONFIG["environments"][environment]["id"], "service": CONFIG["service_id"], "sha": sha},
    )["serviceInstanceDeployV2"]
    print(f"Requested {environment} deployment {deployment_id} for {sha}", flush=True)
    output("deployment_id", deployment_id)
    deadline = time.monotonic() + timeout
    previous_status = None
    while time.monotonic() < deadline:
        deployment = railway(DEPLOYMENT_QUERY, {"id": deployment_id})["deployment"]
        check_scope(deployment, environment)
        status = deployment["status"]
        if status != previous_status:
            print(f"{deployment_id}: {status}", flush=True)
            previous_status = status
        if status == "SUCCESS":
            check_scope(deployment, environment, sha)
            if deployment["deploymentStopped"]:
                raise DeploymentError("Deployment succeeded but has already stopped")
            smoke_check(environment)
            summary = (
                f"### Backend: {environment}\n\nCommit: `{sha}`\n\n"
                f"Railway deployment: `{deployment_id}`\n\n"
                f"[Open backend]({CONFIG['environments'][environment]['url']}/health)\n"
            )
            if environment == "staging":
                summary += "\nAfter testing on a phone, use this deployment ID in **Promote backend to production**.\n"
            if path := os.environ.get("GITHUB_STEP_SUMMARY"):
                with Path(path).open("a") as handle:
                    handle.write(summary)
            print(f"Verified {environment}: {sha} ({deployment_id})", flush=True)
            return deployment_id
        if status not in PENDING:
            raise DeploymentError(f"Deployment {deployment_id} ended in {status}; inspect Railway before retrying")
        time.sleep(10)
    raise DeploymentError(f"Timed out waiting for {deployment_id}; inspect that deployment before retrying")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("validate-staging")
    inspect.add_argument("--deployment", required=True)
    publish = commands.add_parser("deploy")
    publish.add_argument("--environment", choices=["staging", "production"], required=True)
    publish.add_argument("--sha", required=True)
    args = parser.parse_args()
    try:
        if args.command == "validate-staging":
            inspect_staging(args.deployment)
        else:
            deploy(args.environment, args.sha)
    except DeploymentError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
