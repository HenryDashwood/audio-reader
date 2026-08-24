#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_root="${HEARFUL_PACKAGE_ROOT:-$(cd "$repo_root/.." && pwd)/kokoro-packages}"

misaki_revision="6835a1ce4a8854075c89f18ff75c74b13ef58e15"
kokoro_revision="87602d0738306758921df1aeef55785b091104e7"

checkout() {
  local name="$1"
  local url="$2"
  local revision="$3"
  local destination="$packages_root/$name"

  if [[ ! -e "$destination" ]]; then
    git clone --filter=blob:none --no-checkout "$url" "$destination"
    git -C "$destination" checkout --detach "$revision"
  elif [[ ! -d "$destination/.git" ]]; then
    echo "error: $destination exists but is not a Git checkout" >&2
    exit 1
  fi

  local actual_revision
  actual_revision="$(git -C "$destination" rev-parse HEAD)"
  if [[ "$actual_revision" != "$revision" ]]; then
    echo "error: $destination is at $actual_revision; expected $revision" >&2
    echo "Move it aside or set HEARFUL_PACKAGE_ROOT to an empty directory." >&2
    exit 1
  fi
}

apply_package_patch() {
  local name="$1"
  local patch="$repo_root/ios/PackagePatches/$2"
  local destination="$packages_root/$name"

  if git -C "$destination" apply --reverse --check "$patch" >/dev/null 2>&1; then
    return
  fi

  git -C "$destination" apply --check "$patch"
  git -C "$destination" apply "$patch"
}

mkdir -p "$packages_root"
checkout "MisakiSwift" "https://github.com/mlalma/MisakiSwift.git" "$misaki_revision"
checkout "kokoro-ios" "https://github.com/mlalma/kokoro-ios.git" "$kokoro_revision"
apply_package_patch "MisakiSwift" "MisakiSwift.patch"
apply_package_patch "kokoro-ios" "kokoro-ios.patch"

echo "Kokoro packages are ready in $packages_root"
