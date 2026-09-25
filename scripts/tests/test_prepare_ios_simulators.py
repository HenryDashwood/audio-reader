"""CI runtime provisioning must tolerate Xcode's already-downloaded exit code."""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest


def runtime(version, *, available=True, build="24A434"):
    return {
        "identifier": f"com.apple.CoreSimulator.SimRuntime.iOS-{version.replace('.', '-')}",
        "version": version,
        "isAvailable": available,
        "buildversion": build,
    }


@pytest.fixture
def prepare(tmp_path):
    tools = tmp_path / "bin"
    tools.mkdir()
    jq = shutil.which("jq")
    assert jq is not None, "Simulator preparation requires jq"
    (tools / "jq").symlink_to(jq)

    def executable(name, contents):
        path = tools / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + contents)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    executable(
        "xcodebuild",
        """
echo "download $4" >> "$FAKE_STATE/calls"
if [[ -f "$FAKE_STATE/download-$4.json" ]]; then
  cp "$FAKE_STATE/download-$4.json" "$FAKE_STATE/runtimes.json"
fi
exit "$FAKE_DOWNLOAD_STATUS"
""",
    )
    executable(
        "xcrun",
        """
if [[ "$1 $2 $3" == "simctl list runtimes" ]]; then
  cat "$FAKE_STATE/runtimes.json"
elif [[ "$1 $2 $3" == "simctl list devices" ]]; then
  cat "$FAKE_STATE/devices.json"
elif [[ "$1 $2" == "simctl create" ]]; then
  echo "create $5" >> "$FAKE_STATE/calls"
  echo 'new-simulator'
  exit "$FAKE_CREATE_STATUS"
else
  exit 99
fi
""",
    )

    def run(initial, *, downloads=None, devices=None, status=0, create_status=0, versions=()):
        (tmp_path / "runtimes.json").write_text(json.dumps({"runtimes": initial}))
        (tmp_path / "devices.json").write_text(json.dumps({"devices": devices or {}}))
        for version, inventory in (downloads or {}).items():
            (tmp_path / f"download-{version}.json").write_text(json.dumps({"runtimes": inventory}))
        result = subprocess.run(
            ["/bin/bash", Path(__file__).resolve().parents[1] / "prepare-ios-simulators.sh", *versions],
            env=os.environ
            | {
                "PATH": f"{tools}:/usr/bin:/bin",
                "FAKE_STATE": str(tmp_path),
                "FAKE_DOWNLOAD_STATUS": str(status),
                "FAKE_CREATE_STATUS": str(create_status),
            },
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        calls = tmp_path / "calls"
        return result, calls.read_text().splitlines() if calls.exists() else []

    return run


def phones(runtimes):
    return {
        item["identifier"]: [{"name": "iPhone 17", "udid": item["version"], "isAvailable": True}] for item in runtimes
    }


def test_installed_runtimes_and_devices_are_reused(prepare):
    inventory = [runtime("27.0"), runtime("26.5")]
    for _ in range(2):
        result, calls = prepare(inventory, devices=phones(inventory), status=70)
        assert result.returncode == 0, result.stderr
        assert calls == []
        assert result.stdout.count("Ready:") == 2


@pytest.mark.parametrize("status", [0, 70])
def test_existing_ios27_does_not_prevent_installing_ios26(prepare, status):
    initial = [runtime("27.0")]
    installed = initial + [runtime("26.5")]
    result, calls = prepare(initial, downloads={"26.5": installed}, devices=phones(initial), status=status)
    assert result.returncode == 0, result.stderr
    assert calls == ["download 26.5", "create com.apple.CoreSimulator.SimRuntime.iOS-26-5"]


@pytest.mark.parametrize("status", [0, 70])
def test_download_without_available_runtime_still_fails(prepare, status):
    initial = [runtime("27.0")]
    result, calls = prepare(initial, devices=phones(initial), status=status)
    assert result.returncode != 0
    assert f"released iOS 26.5 is not available after download (exit {status})" in result.stderr
    assert calls == ["download 26.5"]


@pytest.mark.parametrize("unusable", [runtime("27.0", available=False), runtime("27.0", build="24A5000a")])
def test_unavailable_or_beta_runtime_requires_installation(prepare, unusable):
    installed = [runtime("27.0"), runtime("26.5")]
    result, calls = prepare([unusable, runtime("26.5")], downloads={"27.0": installed}, devices=phones(installed))
    assert result.returncode == 0, result.stderr
    assert calls == ["download 27.0"]


def test_device_creation_failure_is_not_hidden(prepare):
    result, calls = prepare([runtime("27.0"), runtime("26.5")], create_status=42)
    assert result.returncode == 42
    assert calls == ["create com.apple.CoreSimulator.SimRuntime.iOS-27-0"]


def test_a_requested_version_prepares_only_that_runtime(prepare):
    initial = [runtime("27.0")]
    installed = initial + [runtime("26.5")]
    result, calls = prepare(initial, downloads={"26.5": installed}, versions=["26.5"])
    assert result.returncode == 0, result.stderr
    assert calls == ["download 26.5", "create com.apple.CoreSimulator.SimRuntime.iOS-26-5"]
    assert result.stdout.count("Ready:") == 1


def test_requesting_ios27_does_not_download_ios26(prepare):
    initial = [runtime("27.0")]
    result, calls = prepare(initial, devices=phones(initial), versions=["27.0"])
    assert result.returncode == 0, result.stderr
    assert calls == []
    assert result.stdout.count("Ready:") == 1
