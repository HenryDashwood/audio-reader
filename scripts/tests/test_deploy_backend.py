"""Deployment safety checks: fail closed on wrong commits, scopes and CI state."""

import importlib.util
import io
import urllib.error
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "deploy_backend", Path(__file__).resolve().parents[1] / "deploy_backend.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SHA = "a" * 40
DEPLOYMENT_ID = "11111111-1111-4111-8111-111111111111"


def test_railway_requests_identify_client_to_edge(monkeypatch):
    monkeypatch.setenv("RAILWAY_TOKEN", "test-project-token")

    def urlopen(request, timeout):
        agent = request.get_header("User-agent", "")
        if not agent or agent.startswith("Python-urllib"):
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, None)
        assert request.get_header("Project-access-token") == "test-project-token"
        return io.BytesIO(b'{"data":{"__typename":"Query"}}')

    monkeypatch.setattr(module.urllib.request, "urlopen", urlopen)
    assert module.railway("query { __typename }", {}) == {"__typename": "Query"}


def test_http_error_reports_status_without_leaking_secrets_or_retrying(monkeypatch):
    calls = []

    def urlopen(request, timeout):
        calls.append(request)
        raise urllib.error.HTTPError(
            request.full_url, 403, "secret-reason", {"secret-header": "secret-value"}, io.BytesIO(b"secret-body")
        )

    monkeypatch.setattr(module.urllib.request, "urlopen", urlopen)
    with pytest.raises(module.DeploymentError) as error:
        module.request_json(module.RAILWAY_API, headers={"Project-Access-Token": "secret-token"}, data=b"{}")
    assert str(error.value) == "Request to backboard.railway.com failed: HTTP 403"
    assert len(calls) == 1


def deployment(environment="staging", **changes):
    return {
        "id": DEPLOYMENT_ID,
        "projectId": module.CONFIG["project_id"],
        "serviceId": module.CONFIG["service_id"],
        "environmentId": module.CONFIG["environments"][environment]["id"],
        "status": "SUCCESS",
        "deploymentStopped": False,
        "meta": {"commitHash": SHA},
    } | changes


def test_staging_validation_uses_the_deployed_commit(monkeypatch, tmp_path):
    seen = []
    monkeypatch.setattr(module, "railway", lambda query, variables: {"deployment": deployment()})
    monkeypatch.setattr(module, "verify_ci", seen.append)
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    assert module.inspect_staging(DEPLOYMENT_ID) == SHA
    assert seen == [SHA]
    assert f"sha={SHA}" in output.read_text()


@pytest.mark.parametrize(
    "changes",
    [
        {"environmentId": module.CONFIG["environments"]["production"]["id"]},
        {"serviceId": "database"},
        {"projectId": "other-project"},
        {"status": "FAILED"},
        {"status": "BUILDING"},
        {"status": "REMOVED"},
        {"deploymentStopped": True},
        {"meta": {"commitHash": "main"}},
        {"meta": None},
    ],
)
def test_invalid_staging_is_never_promotable(monkeypatch, changes):
    monkeypatch.setattr(module, "railway", lambda query, variables: {"deployment": deployment(**changes)})
    monkeypatch.setattr(module, "verify_ci", lambda sha: pytest.fail("Must reject before checking CI"))
    with pytest.raises(module.DeploymentError):
        module.inspect_staging(DEPLOYMENT_ID)


def test_latest_failed_ci_rerun_overrides_previous_success(monkeypatch):
    runs = [
        {
            "id": 1,
            "head_sha": SHA,
            "head_branch": "main",
            "event": "push",
            "status": "completed",
            "conclusion": "success",
        },
        {
            "id": 2,
            "head_sha": SHA,
            "head_branch": "main",
            "event": "push",
            "status": "completed",
            "conclusion": "failure",
        },
    ]
    monkeypatch.setattr(
        module, "github", lambda path: {"status": "ahead"} if path.startswith("compare/") else {"workflow_runs": runs}
    )
    with pytest.raises(module.DeploymentError, match="successful main CI"):
        module.verify_ci(SHA)


@pytest.mark.parametrize(
    "branch,status,event",
    [("feature", "success", "push"), ("main", "failure", "push"), ("main", "success", "pull_request")],
)
def test_wrong_ci_run_is_not_accepted(monkeypatch, branch, status, event):
    runs = [
        {"id": 1, "head_sha": SHA, "head_branch": branch, "event": event, "status": "completed", "conclusion": status}
    ]
    monkeypatch.setattr(
        module,
        "github",
        lambda path: {"status": "identical"} if path.startswith("compare/") else {"workflow_runs": runs},
    )
    with pytest.raises(module.DeploymentError):
        module.verify_ci(SHA)


def test_unmerged_commit_is_rejected(monkeypatch):
    monkeypatch.setattr(module, "github", lambda path: {"status": "diverged"})
    with pytest.raises(module.DeploymentError, match="ancestor"):
        module.verify_ci(SHA)


@pytest.mark.parametrize("missing", [None, "Released iOS client compatibility", "Deploy backend to staging"])
def test_main_ci_requires_all_release_gates(monkeypatch, missing):
    run = {
        "id": 1,
        "head_sha": SHA,
        "head_branch": "main",
        "event": "push",
        "status": "completed",
        "conclusion": "success",
    }

    def github(path):
        if path.startswith("compare/"):
            return {"status": "ahead"}
        if "/jobs?" in path:
            return {
                "jobs": [
                    {"name": name, "conclusion": "success"} for name in module.REQUIRED_CI_JOBS if name != missing
                ]
            }
        return {"workflow_runs": [run]}

    monkeypatch.setattr(module, "github", github)
    if missing:
        with pytest.raises(module.DeploymentError, match="release gates"):
            module.verify_ci(SHA)
    else:
        module.verify_ci(SHA)


def test_deploy_tracks_returned_id_and_exact_sha(monkeypatch):
    calls = []
    statuses = iter(["BUILDING", "DEPLOYING", "SUCCESS"])

    def railway(query, variables):
        calls.append(variables)
        if "mutation" in query:
            return {"serviceInstanceDeployV2": DEPLOYMENT_ID}
        return {"deployment": deployment("production", status=next(statuses))}

    monkeypatch.setattr(module, "railway", railway)
    monkeypatch.setattr(module.time, "sleep", lambda _: None)
    monkeypatch.setattr(module, "smoke_check", lambda environment: calls.append(environment))
    assert module.deploy("production", SHA) == DEPLOYMENT_ID
    assert calls[0]["sha"] == SHA
    assert calls[1:4] == [{"id": DEPLOYMENT_ID}] * 3
    assert calls[-1] == "production"


@pytest.mark.parametrize(
    "changes",
    [
        {"meta": {"commitHash": "b" * 40}},
        {"status": "FAILED"},
        {"status": "NEEDS_APPROVAL"},
        {"status": "SKIPPED"},
        {"deploymentStopped": True},
        {"serviceId": "other-service"},
    ],
)
def test_deploy_cannot_report_a_wrong_or_unsuccessful_deployment(monkeypatch, changes):
    def railway(query, variables):
        return (
            {"serviceInstanceDeployV2": DEPLOYMENT_ID}
            if "mutation" in query
            else {"deployment": deployment(**changes)}
        )

    monkeypatch.setattr(module, "railway", railway)
    monkeypatch.setattr(module, "smoke_check", lambda _: pytest.fail("Must not report success"))
    with pytest.raises(module.DeploymentError):
        module.deploy("staging", SHA)


def test_mutation_is_not_retried_after_network_failure(monkeypatch):
    calls = []

    def railway(query, variables):
        calls.append(query)
        raise module.DeploymentError("network failure")

    monkeypatch.setattr(module, "railway", railway)
    with pytest.raises(module.DeploymentError):
        module.deploy("staging", SHA)
    assert len(calls) == 1


@pytest.mark.parametrize("sha", ["main", "a" * 39, "x" * 40, "a" * 40 + "\n", "$(echo bad)"])
def test_deploy_rejects_nonimmutable_refs_before_mutation(monkeypatch, sha):
    monkeypatch.setattr(module, "railway", lambda *_: pytest.fail("No mutation allowed"))
    with pytest.raises(module.DeploymentError):
        module.deploy("staging", sha)
