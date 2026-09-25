#!/usr/bin/env bash

set -euo pipefail

# xcodebuild can exit 70 for an already-downloaded runtime. Availability in
# CoreSimulator, rather than that exit code or message, is the success check.
available_runtime() {
  xcrun simctl list runtimes -j | jq -r --arg version "$1" '
    [.runtimes[]
      | select(.isAvailable == true and .version == $version)
      | select(.identifier | contains(".iOS-"))
      | select((.buildversion // "") | test("[a-z]$") | not)
    ] | first.identifier // empty
  '
}

# Prepares both released runtimes by default. CI's parallel jobs each pass the
# one version they test, so neither downloads a runtime it will not use.
if (( $# == 0 )); then
  set -- 27.0 26.5
fi

for version in "$@"; do
  runtime_id="$(available_runtime "$version")"
  if [[ -z "$runtime_id" ]]; then
    download_status=0
    xcodebuild -downloadPlatform iOS -buildVersion "$version" || download_status=$?
    runtime_id="$(available_runtime "$version")"
    if [[ -z "$runtime_id" ]]; then
      echo "error: released iOS $version is not available after download (exit $download_status)" >&2
      exit 1
    fi
  fi

  simulator_id="$(xcrun simctl list devices available -j | jq -r --arg runtime "$runtime_id" '
    [(.devices[$runtime] // [])[]
      | select(.isAvailable == true and .name == "iPhone 17")
    ] | first.udid // empty
  ')"
  if [[ -z "$simulator_id" ]]; then
    simulator_id="$(xcrun simctl create 'iPhone 17' com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime_id")"
  fi
  echo "Ready: iPhone 17 on released iOS $version ($simulator_id)"
done
