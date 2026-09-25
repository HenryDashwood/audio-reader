"""TestFlight may skip its iOS tests only when CI provably ran them on the same sources."""

import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import ios_ci_coverage as coverage

ROOT = Path(__file__).resolve().parents[2]
SHA = "a" * 40
OLDER = "b" * 40
NEWER = "c" * 40


def run(run_id, head_sha):
    return {
        "id": run_id,
        "head_sha": head_sha,
        "head_branch": "main",
        "event": "push",
        "run_attempt": 1,
        "html_url": f"https://github.com/runs/{run_id}",
    }


def fake_github(monkeypatch, runs, jobs, comparisons):
    """jobs: run id -> iOS job conclusion (None = absent); comparisons: base sha -> (status, files)."""
    calls = []

    def github(path):
        calls.append(path)
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": runs}
        if match := re.fullmatch(r"actions/runs/(\d+)/attempts/1/jobs\?per_page=100", path):
            conclusion = jobs[int(match[1])]
            if conclusion is None:
                return {"jobs": [{"name": "Backend checks", "status": "completed", "conclusion": "success"}]}
            status = "in_progress" if conclusion == "in_progress" else "completed"
            return {"jobs": [{"name": "iOS tests", "status": status, "conclusion": conclusion}]}
        if match := re.fullmatch(r"compare/([0-9a-f]{40})\.\.\.([0-9a-f]{40})", path):
            status, files = comparisons[match[1]]
            return {"status": status, "files": [{"filename": f} if isinstance(f, str) else f for f in files]}
        raise AssertionError(path)

    monkeypatch.setattr(coverage, "github", github)
    return calls


def test_tests_passed_on_this_commit(monkeypatch):
    fake_github(monkeypatch, [run(1, SHA)], {1: "success"}, {SHA: ("identical", [])})
    assert coverage.check(SHA)["head_sha"] == SHA


def test_skipped_runs_fall_back_to_the_last_tested_ancestor(monkeypatch):
    runs = [run(2, SHA), run(1, OLDER)]
    fake_github(
        monkeypatch,
        runs,
        {2: "skipped", 1: "success"},
        {OLDER: ("ahead", ["docs/CHANGELOG.md", "backend/src/app.py", "android/app/build.gradle.kts"])},
    )
    assert coverage.check(SHA)["head_sha"] == OLDER


def test_later_main_commits_are_ignored(monkeypatch):
    runs = [run(3, NEWER), run(1, SHA)]
    fake_github(monkeypatch, runs, {3: "failure", 1: "success"}, {NEWER: ("behind", []), SHA: ("identical", [])})
    assert coverage.check(SHA)["head_sha"] == SHA


@pytest.mark.parametrize(
    "changed",
    [
        "ios/Hearful/ContentView.swift",
        "app-store/metadata/en-GB/description.txt",
        "scripts/ios-dev.sh",
        ".github/workflows/ci.yml",
        "Makefile",
    ],
)
def test_changed_ios_inputs_require_a_test_run(monkeypatch, changed):
    fake_github(monkeypatch, [run(2, SHA), run(1, OLDER)], {2: "skipped", 1: "success"}, {OLDER: ("ahead", [changed])})
    with pytest.raises(coverage.NotCovered, match="inputs changed"):
        coverage.check(SHA)


def test_renamed_out_of_ios_still_counts(monkeypatch):
    renamed = {"filename": "docs/x.swift", "previous_filename": "ios/Hearful/x.swift"}
    fake_github(monkeypatch, [run(1, OLDER)], {1: "success"}, {OLDER: ("ahead", [renamed])})
    with pytest.raises(coverage.NotCovered, match="ios/Hearful/x.swift"):
        coverage.check(SHA)


@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "in_progress"])
def test_latest_tested_ancestor_must_have_passed(monkeypatch, conclusion):
    # An older pass does not excuse a newer failure on the same sources.
    runs = [run(2, SHA), run(1, OLDER)]
    fake_github(monkeypatch, runs, {2: conclusion, 1: "success"}, {SHA: ("identical", []), OLDER: ("ahead", [])})
    with pytest.raises(coverage.NotCovered, match="did not pass"):
        coverage.check(SHA)


def test_no_tested_ancestor(monkeypatch):
    fake_github(monkeypatch, [run(2, SHA), run(1, OLDER)], {2: "skipped", 1: None}, {})
    with pytest.raises(coverage.NotCovered, match="no successful"):
        coverage.check(SHA)


def test_diverged_history_is_not_trusted(monkeypatch):
    fake_github(monkeypatch, [run(1, OLDER)], {1: "success"}, {OLDER: ("diverged", [])})
    with pytest.raises(coverage.NotCovered):
        coverage.check(SHA)


def test_truncated_file_list_is_not_trusted(monkeypatch):
    files = [f"docs/{index}.md" for index in range(coverage.COMPARE_FILE_LIMIT)]
    fake_github(monkeypatch, [run(1, OLDER)], {1: "success"}, {OLDER: ("ahead", files)})
    with pytest.raises(coverage.NotCovered, match="too many"):
        coverage.check(SHA)


def test_api_errors_run_the_tests(monkeypatch, tmp_path, capsys):
    def github(path):
        raise coverage.DeploymentError("Request to api.github.com failed: HTTP 500")

    monkeypatch.setattr(coverage, "github", github)
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "out"))
    monkeypatch.setattr(sys, "argv", ["ios_ci_coverage.py", "--sha", SHA])
    assert coverage.main() == 0
    assert (tmp_path / "out").read_text() == "covered=false\n"
    assert "Running the iOS tests" in capsys.readouterr().out


def test_covered_writes_outputs(monkeypatch, tmp_path):
    fake_github(monkeypatch, [run(1, SHA)], {1: "success"}, {SHA: ("identical", [])})
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "out"))
    monkeypatch.setattr(sys, "argv", ["ios_ci_coverage.py", "--sha", SHA])
    assert coverage.main() == 0
    assert (tmp_path / "out").read_text() == f"covered=true\ntested_sha={SHA}\n"


def test_inputs_match_the_ci_paths_filter():
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def entries(name):
        block = re.search(rf"^ {{12}}{name}:(?: &\w+)?\n((?: {{14}}- .*\n)+)", workflow, re.MULTILINE)
        assert block, name
        return [line.strip()[2:].strip("'") for line in block[1].splitlines()]

    ios = entries("ios")
    assert ios[0] == "*shared"
    paths = entries("shared") + ios[1:]
    assert [path.removesuffix("**") for path in paths] == list(coverage.IOS_TEST_INPUTS)
