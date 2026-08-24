#!/bin/sh

set -eu

# Xcode Cloud clones only this repository. The Xcode project deliberately
# points at sibling package checkouts so local and CI builds use the same
# patched Kokoro sources without committing them to the app repository.
repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
cd "$repository_root"

./scripts/bootstrap-kokoro-packages.sh
