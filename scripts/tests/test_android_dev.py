"""Device selection and test filtering must not target a connected phone."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def android_runner(tmp_path: Path):
    repo = tmp_path / "repo with spaces"
    (repo / "scripts").mkdir(parents=True)
    (repo / "android").mkdir()
    source = Path(__file__).resolve().parents[2]
    shutil.copy2(source / "scripts/android-dev.sh", repo / "scripts/android-dev.sh")
    shutil.copy2(source / "Makefile", repo / "Makefile")
    sdk = tmp_path / "Android SDK"
    (sdk / "platform-tools").mkdir(parents=True)
    calls = tmp_path / "calls"

    def executable(path, content):
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + content)
        path.chmod(0o755)

    executable(
        repo / "android/gradlew",
        'printf "gradle serial=%s\\n" "${ANDROID_SERIAL:-}" >> "$CALLS"\n'
        'printf "arg=%s\\n" "$@" >> "$CALLS"\n',
    )
    executable(
        sdk / "platform-tools/adb",
        """
printf 'adb %s\n' "$*" >> "$CALLS"
if [[ "$1" == devices ]]; then
    printf '%b\n' "${DEVICES:-emulator-5554 device}"
elif [[ "$3" == get-state ]]; then
    echo "${DEVICE_STATE:-device}"
elif [[ "$3" == shell && "$4" == getprop ]]; then
    echo "${BOOT_COMPLETED:-1}"
fi
""",
    )

    def run(target, **overrides):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ANDROID_", "GRADLE_", "MAKE")) and key != "TEST"
        }
        result = subprocess.run(
            ["make", target],
            cwd=repo,
            env=env | {"ANDROID_HOME": str(sdk), "CALLS": str(calls)} | overrides,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, calls.read_text() if calls.exists() else ""

    return run


@pytest.mark.parametrize("target", ["android-run", "android-test", "android-layout"])
def test_explicit_phone_is_rejected_before_any_device_command(android_runner, target):
    result, calls = android_runner(target, ANDROID_SERIAL="pixel-physical")
    assert result.returncode != 0
    assert "only target emulators" in result.stderr
    assert not calls


@pytest.mark.parametrize(
    "devices",
    ["pixel-physical device", "emulator-5554 device\nemulator-5556 device"],
)
def test_missing_or_ambiguous_emulator_never_installs(android_runner, devices):
    result, calls = android_runner("android-run", DEVICES=devices)
    assert result.returncode != 0
    assert "ANDROID_SERIAL" in result.stderr
    assert "gradle" not in calls
    assert "install" not in calls


def test_connected_phone_is_ignored_and_selected_emulator_reaches_gradle(
    android_runner,
):
    result, calls = android_runner(
        "android-test", DEVICES="pixel-physical device\nemulator-5556 device"
    )
    assert result.returncode == 0, result.stderr
    assert "gradle serial=emulator-5556" in calls
    assert "arg=connectedDebugAndroidTest" in calls


@pytest.mark.parametrize(
    "overrides", [{"DEVICE_STATE": "offline"}, {"BOOT_COMPLETED": "0"}]
)
def test_unready_emulator_never_installs(android_runner, overrides):
    result, calls = android_runner(
        "android-run", ANDROID_SERIAL="emulator-5554", **overrides
    )
    assert result.returncode != 0
    assert "gradle" not in calls
    assert "install" not in calls


def test_run_updates_existing_install_on_explicit_emulator(android_runner):
    result, calls = android_runner("android-run", ANDROID_SERIAL="emulator-5556")
    assert result.returncode == 0, result.stderr
    assert "adb -s emulator-5556 install -r " in calls
    assert "adb -s emulator-5556 shell am start -W" in calls
    assert "uninstall" not in calls


def test_unit_test_pattern_is_one_literal_argument(android_runner):
    result, calls = android_runner("android-unit-test", TEST="*ArticleChunksTest")
    assert result.returncode == 0, result.stderr
    assert "arg=--tests\narg=*ArticleChunksTest\n" in calls
    assert "adb" not in calls


def test_instrumentation_filter_and_serial_reach_gradle(android_runner):
    result, calls = android_runner(
        "android-test",
        ANDROID_SERIAL="emulator-5556",
        TEST="com.example.NavigationTest#opensReader",
    )
    assert result.returncode == 0, result.stderr
    assert "gradle serial=emulator-5556" in calls
    assert (
        "arg=-Pandroid.testInstrumentationRunnerArguments.class="
        "com.example.NavigationTest#opensReader\n"
    ) in calls


def test_full_gate_ignores_test_filter_and_builds_instrumentation_apk(android_runner):
    result, calls = android_runner("android-check", TEST="*OneTest")
    assert result.returncode == 0, result.stderr
    for task in (
        "assembleDebug",
        "assembleDebugAndroidTest",
        "testDebugUnitTest",
        "lintDebug",
    ):
        assert f"arg={task}\n" in calls
    assert "OneTest" not in calls
    assert "adb" not in calls
