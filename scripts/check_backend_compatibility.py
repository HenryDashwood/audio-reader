#!/usr/bin/env python3
"""Run today's backend exchanges through the released Swift HTTP client on macOS."""

import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="magpie-compatibility-") as directory:
        work = Path(directory)
        exchanges = work / "exchanges.json"
        subprocess.run(
            ["uv", "run", "pytest", "tests/test_released_client_contract.py", "-q"],
            cwd=ROOT / "backend",
            check=True,
            env=os.environ | {"MAGPIE_CONTRACT_OUTPUT": str(exchanges)},
        )
        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "6",
                "-parse-as-library",
                *map(str, sorted((ROOT / "compatibility/ios-v1.4.1").glob("*.swift"))),
                str(ROOT / "compatibility/ClientSupport.swift"),
                str(ROOT / "compatibility/CheckClient.swift"),
                "-o",
                str(work / "check-client"),
            ],
            check=True,
        )
        subprocess.run([str(work / "check-client"), str(exchanges)], check=True)


if __name__ == "__main__":
    main()
