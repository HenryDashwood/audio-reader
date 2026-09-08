"""Regression checks for the shell wrapper around the iOS toolchain."""

import os
import stat
import subprocess
from pathlib import Path

import pytest


def _executable(path: Path, contents: str) -> None:
    path.write_text("#!/bin/bash\nset -euo pipefail\n" + contents)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_doctor_consumes_version_output_without_sigpipe(tmp_path: Path) -> None:
    """A slow second line must not turn `pipefail` into exit 141.

    GitHub's macOS runner exposed this race when `grep -m 1` and `head -n 1`
    exited after their first match while Xcode was still writing its ordinary
    second version line.
    """
    tools = tmp_path / "bin"
    tools.mkdir()
    _executable(
        tools / "xcodebuild",
        """
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode 26.4\\n'
  sleep 0.05
  printf 'Build version 17A400\\n'
elif [[ "${1:-}" == "-checkFirstLaunchStatus" ]]; then
  exit 0
else
  exit 2
fi
""",
    )
    _executable(
        tools / "xcrun",
        """
if [[ "${1:-}" == "simctl" ]]; then
  printf '{}\\n'
elif [[ "${1:-}" == "swift" ]]; then
  printf 'Apple Swift version 6.2 (swiftlang-6.2.0.1)\\n'
  sleep 0.05
  printf 'Target: arm64-apple-macosx\\n'
else
  exit 2
fi
""",
    )
    _executable(tools / "jq", "cat >/dev/null\nprintf 'iPhone 17\\n'\n")
    _executable(tools / "xcode-select", "printf '/Applications/Xcode.app/Contents/Developer\\n'\n")

    repo = Path(__file__).resolve().parents[2]
    environment = os.environ | {
        "PATH": f"{tools}:/usr/bin:/bin",
        "IOS_SIMULATOR_ID": "test-simulator",
    }
    result = subprocess.run(
        [repo / "scripts" / "ios-dev.sh", "doctor"],
        cwd=repo,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Xcode: Xcode 26.4 Build version 17A400" in result.stdout
    assert "Swift: Apple Swift version 6.2" in result.stdout
    assert "iOS toolchain is ready." in result.stdout


@pytest.fixture
def ios_runner(tmp_path: Path):
    """Run the real Makefile/wrapper with a controlled Apple toolchain.

    The boot/build handshake proves overlap without relying on elapsed time.
    No simulator, Xcode installation or network is required.
    """
    tools = tmp_path / "bin"
    tools.mkdir()
    calls = tmp_path / "calls"
    calls.mkdir()
    _executable(
        tools / "xcodebuild",
        """
printf '%s\\n' "$@" > "$FAKE_CALLS/$1.args"
if [[ "$1" == build-for-testing ]]; then
  if [[ "${FAKE_HANDSHAKE:-0}" == 1 ]]; then
    for ((i=0; i<200; i++)); do
      [[ -f "$FAKE_CALLS/boot-started" ]] && break
      sleep 0.01
    done
    [[ -f "$FAKE_CALLS/boot-started" ]] || exit 99
  fi
  touch "$FAKE_CALLS/build-finished"
  exit "${FAKE_BUILD_STATUS:-0}"
fi
if [[ "$1" == test-without-building ]]; then
  [[ -f "$FAKE_CALLS/boot-finished" ]] || exit 98
fi
exit "${FAKE_TEST_STATUS:-0}"
""",
    )
    _executable(
        tools / "xcrun",
        """
if [[ "$2" == bootstatus ]]; then
  printf '%s\\n' "$@" > "$FAKE_CALLS/boot.args"
  touch "$FAKE_CALLS/boot-started"
  if [[ "${FAKE_BLOCK_BOOT:-0}" == 1 ]]; then
    echo "$$" > "$FAKE_CALLS/boot.pid"
    exec sleep 60
  fi
  if [[ "${FAKE_HANDSHAKE:-0}" == 1 ]]; then
    for ((i=0; i<200; i++)); do
      [[ -f "$FAKE_CALLS/build-finished" ]] && break
      sleep 0.01
    done
    [[ -f "$FAKE_CALLS/build-finished" ]] || exit 97
  fi
  touch "$FAKE_CALLS/boot-finished"
  echo 'Simulator boot elapsed time: 0s'
  exit "${FAKE_BOOT_STATUS:-0}"
fi
printf '{}\\n'
""",
    )
    _executable(tools / "jq", "cat >/dev/null\nprintf 'iPhone 17\\n'\n")
    _executable(tools / "xcbeautify", "cat\n")
    _executable(tools / "xcode-build-server", "cat >/dev/null\n")
    # Copy the wrapper/Makefile so even the index log stays in the test sandbox.
    repo = Path(__file__).resolve().parents[2]
    sandbox = tmp_path / "repo"
    (sandbox / "scripts").mkdir(parents=True)
    wrapper = sandbox / "scripts" / "ios-dev.sh"
    wrapper.write_bytes((repo / "scripts" / "ios-dev.sh").read_bytes())
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
    (sandbox / "Makefile").write_bytes((repo / "Makefile").read_bytes())

    def run(target="ios-test", *, test=None, **overrides):
        environment = (
            {
                key: value
                for key, value in os.environ.items()
                if not key.startswith(("IOS_", "GITHUB_", "MAKE")) and key != "TEST"
            }
            | {
                "PATH": f"{tools}:/usr/bin:/bin",
                "IOS_SIMULATOR_ID": "test-simulator",
                "IOS_DERIVED_DATA_PATH": str(tmp_path / "normal output"),
                "FAKE_CALLS": str(calls),
                "GITHUB_STEP_SUMMARY": str(tmp_path / "summary.md"),
            }
            | overrides
        )
        command = ["make", target]
        if test is not None:
            command.append(f"TEST={test}")
        result = subprocess.run(
            command, cwd=sandbox, env=environment, text=True, capture_output=True, timeout=10, check=False
        )
        arguments = {path.stem: path.read_text().splitlines() for path in calls.glob("*.args")}
        return result, arguments

    return run


@pytest.mark.parametrize(
    ("target", "test", "expected"),
    [
        ("ios-test", None, None),
        ("ios-test", "VoiceControllerTests", "HearfulTests/VoiceControllerTests"),
        ("ios-test-latest", "VoiceControllerTests/example()", "HearfulTests/VoiceControllerTests/example()"),
        ("ios-test", "HearfulTests/VoiceControllerTests", "HearfulTests/VoiceControllerTests"),
    ],
)
def test_local_filter_preserves_single_incremental_invocation(ios_runner, target, test, expected):
    result, calls = ios_runner(target, test=test)
    assert result.returncode == 0, result.stderr
    assert set(calls) == {"test"}
    filters = [argument for argument in calls["test"] if argument.startswith("-only-testing:")]
    assert filters == ([] if expected is None else [f"-only-testing:{expected}"])
    assert "clean" not in calls["test"]


def test_boot_overlaps_build_and_tests_wait_for_both(ios_runner, tmp_path):
    result, calls = ios_runner(
        test="VoiceControllerTests", IOS_TEST_PREBOOT="1", IOS_COMPILATION_CACHE="1", FAKE_HANDSHAKE="1"
    )
    assert result.returncode == 0, result.stderr
    assert set(calls) == {"build-for-testing", "test-without-building", "boot"}
    assert calls["boot"] == ["simctl", "bootstatus", "test-simulator", "-b"]
    for action in ("build-for-testing", "test-without-building"):
        assert "COMPILATION_CACHE_ENABLE_CACHING=YES" in calls[action]
        assert str(tmp_path / "normal output") in calls[action]
        assert "platform=iOS Simulator,id=test-simulator" in calls[action]
    assert "-only-testing:HearfulTests/VoiceControllerTests" in calls["test-without-building"]
    summary = (tmp_path / "summary.md").read_text()
    assert "Build for testing:" in summary
    assert "Simulator wait after build:" in summary
    assert "Total phased test run:" in summary


@pytest.mark.parametrize("failure", ["FAKE_BUILD_STATUS", "FAKE_BOOT_STATUS", "FAKE_TEST_STATUS"])
def test_phased_failures_fail_make_and_never_test_after_failed_preparation(ios_runner, failure):
    result, calls = ios_runner(IOS_TEST_PREBOOT="1", **{failure: "65"})
    assert result.returncode != 0
    assert "Error 65" in result.stderr
    assert ("test-without-building" in calls) == (failure == "FAKE_TEST_STATUS")


def test_formatter_does_not_hide_local_test_failure(ios_runner):
    result, _ = ios_runner(FAKE_TEST_STATUS="65")
    assert result.returncode != 0
    assert "Error 65" in result.stderr


def test_build_failure_stops_background_boot(ios_runner, tmp_path):
    result, calls = ios_runner(IOS_TEST_PREBOOT="1", FAKE_BUILD_STATUS="65", FAKE_BLOCK_BOOT="1", FAKE_HANDSHAKE="1")
    assert result.returncode != 0
    assert "Error 65" in result.stderr
    assert "test-without-building" not in calls
    boot_pid = int((tmp_path / "calls/boot.pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(boot_pid, 0)


@pytest.mark.parametrize("custom", [False, True])
def test_index_clean_uses_separate_output_even_with_normal_override(ios_runner, tmp_path, custom):
    index_path = tmp_path / "custom index" if custom else tmp_path / "repo/build/IndexDerivedData"
    overrides = {"IOS_INDEX_DERIVED_DATA_PATH": str(index_path)} if custom else {}
    result, calls = ios_runner("ios-index", **overrides)
    assert result.returncode == 0, result.stderr
    assert calls["clean"][:2] == ["clean", "build-for-testing"]
    assert str(index_path) in calls["clean"]
    assert str(tmp_path / "normal output") not in calls["clean"]
