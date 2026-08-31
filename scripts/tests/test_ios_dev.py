"""Regression checks for the shell wrapper around the iOS toolchain."""

import os
import stat
import subprocess
from pathlib import Path


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
