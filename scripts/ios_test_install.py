"""Run simulator tests, recovering once from a stuck Xcode install handoff."""

import os
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path


def install_state(bundle, simulator):
    # Xcode's stdout just says "Testing started" throughout install and launch.
    # Its per-session diagnostic records the actual install request and reply.
    pending = False
    for path in bundle.glob("Staging/*/Diagnostics/*/*/Session-*.log"):
        try:
            with path.open("rb") as log:
                # Install precedes launch. Avoid parsing megabytes of later test output.
                prefix = log.read(256 * 1024)
                complete = not log.read(1)
        except FileNotFoundError:
            continue  # Xcode moves diagnostics when it finalizes the result bundle.
        for line in prefix.splitlines():
            if b"/Magpie.app and options:" not in line:
                continue
            if f"] {simulator}: Installed app at path: ".encode() in line:
                return "installed"
            if complete and f"] {simulator}: Installing app at path: ".encode() in line:
                pending = True
    return "pending" if pending else "unknown"


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def run_attempt(arguments, simulator, bundle, timeout):
    process = subprocess.Popen(["xcodebuild", *arguments, "-resultBundlePath", str(bundle)])
    deadline = None
    try:
        while process.poll() is None:
            state = install_state(bundle, simulator)
            if state == "installed":
                return process.wait()
            if state != "pending":
                deadline = None
            elif deadline is None:
                deadline = time.monotonic() + timeout
            elif time.monotonic() >= deadline:
                print(
                    f"warning: Magpie install on {simulator} pending for {timeout}s. Diagnostics: {bundle}",
                    file=sys.stderr,
                    flush=True,
                )
                return None
            try:
                return process.wait(timeout=min(2, timeout))
            except subprocess.TimeoutExpired:
                pass
        return process.returncode
    finally:
        stop(process)


def main():
    simulator, derived_data, *arguments = sys.argv[1:]
    try:
        timeout = int(os.environ.get("IOS_TEST_INSTALL_TIMEOUT", "180"))
        if timeout <= 0:
            raise ValueError
    except ValueError:
        sys.exit("IOS_TEST_INSTALL_TIMEOUT must be a positive number of seconds")

    results = Path(derived_data) / "Logs/Test"
    results.mkdir(parents=True, exist_ok=True)
    for attempt in (1, 2):
        bundle = results / f"Test-Hearful-{uuid.uuid4()}.xcresult"
        status = run_attempt(arguments, simulator, bundle, timeout)
        if status is not None:
            return status if status >= 0 else 128 - status
        if attempt == 2:
            print("error: Magpie install stalled again after retry.", file=sys.stderr)
            return 124
        print(f"warning: Restarting simulator {simulator} and retrying once.", file=sys.stderr, flush=True)
        for command in (["shutdown", simulator], ["bootstatus", simulator, "-b"]):
            status = subprocess.call(["xcrun", "simctl", *command])
            if status:
                return status


if __name__ == "__main__":
    # Run cleanup on CI cancellation as well as an interactive Ctrl-C.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    sys.exit(main())
