#!/bin/sh

set -eu

# Xcode Cloud only discovers ci_scripts beside the selected Xcode project or
# workspace. Hearful.xcodeproj lives in ios/, while the package bootstrapper
# lives at the repository root.
repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
cd "$repository_root"

./scripts/bootstrap-kokoro-packages.sh
