#!/usr/bin/env bash
set -euo pipefail

display="${DISPLAY:-}"
name="${NAME:-}"
simulator_id="${IOS_SIMULATOR_ID:-}"

case "$display" in
  APP_IPHONE_69|APP_IPAD_PRO_3GEN_129) ;;
  *)
    echo "DISPLAY must be APP_IPHONE_69 or APP_IPAD_PRO_3GEN_129" >&2
    exit 2
    ;;
esac

if [[ ! "$name" =~ ^[0-9][0-9]-[a-z0-9-]+$ ]]; then
  echo "NAME must look like 01-latest (lower-case letters, digits and hyphens)" >&2
  exit 2
fi

if [[ -z "$simulator_id" ]]; then
  echo "IOS_SIMULATOR_ID must identify the simulator whose screen should be captured" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
destination="$repo_root/app-store/screenshots/en-GB/$display/$name.jpg"
raw="$repo_root/build/app-store-screenshot-$display.png"
mkdir -p "$repo_root/build"
trap 'rm -f "$raw"' EXIT

# A stable, full status bar makes images from separate capture sessions look
# like one set. The command affects only this simulator and can be cleared with
# `xcrun simctl status_bar <udid> clear` if desired.
xcrun simctl status_bar "$simulator_id" override \
  --time 9:41 \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4
xcrun simctl io "$simulator_id" screenshot "$raw"
# Simulator PNGs carry an alpha channel even though every pixel is opaque.
# App Store Connect rejects the channel itself, so write a maximum-quality JPEG
# rather than asking every capture session to remember a manual conversion.
sips -s format jpeg -s formatOptions 100 "$raw" --out "$destination" >/dev/null

python3 "$repo_root/scripts/app_store_sync.py" validate
echo "Saved $destination"
