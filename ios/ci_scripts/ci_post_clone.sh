#!/bin/sh

set -eu

# mlx-swift 0.31.6 attaches its CudaBuild package plugin on every platform,
# even though the plugin does no work on Apple platforms. Xcode Cloud cannot
# show the one-time trust prompt, so give the pinned package plugin the same
# non-interactive approval used by our other CI builds.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Xcode Cloud only discovers ci_scripts beside the selected Xcode project or
# workspace. Hearful.xcodeproj lives in ios/, while the package bootstrapper
# lives at the repository root.
repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
cd "$repository_root"

./scripts/bootstrap-kokoro-packages.sh
