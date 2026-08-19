#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/ios/Hearful.xcodeproj"
scheme="Hearful"
derived_data="${IOS_DERIVED_DATA_PATH:-$repo_root/build/DerivedData}"
minimum_os="${IOS_MINIMUM_OS:-26.0}"
preferred_name="${IOS_SIMULATOR_NAME:-iPhone 17}"

usage() {
  echo "Usage: $0 {doctor|build|test|test-latest}"
  echo
  echo "Overrides: IOS_SIMULATOR_ID, IOS_SIMULATOR_NAME, IOS_MINIMUM_OS, IOS_DERIVED_DATA_PATH"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' is not installed" >&2
    exit 1
  fi
}

runtime_policy="minimum"
action="${1:-}"
if [[ "$action" == "test-latest" ]]; then
  runtime_policy="latest"
  action="test"
fi

if [[ "$action" != "doctor" && "$action" != "build" && "$action" != "test" ]]; then
  usage >&2
  exit 2
fi

require xcodebuild
require xcrun
require jq

simulator_id="${IOS_SIMULATOR_ID:-}"
runtime_version=""
simulator_name=""

choose_simulator() {
  if [[ -n "$simulator_id" ]]; then
    simulator_name="$(xcrun simctl list devices -j | jq -r --arg id "$simulator_id" '
      [.devices[][] | select(.udid == $id)] | first.name // empty
    ')"
    if [[ -z "$simulator_name" ]]; then
      echo "error: IOS_SIMULATOR_ID '$simulator_id' is not an installed simulator" >&2
      exit 1
    fi
    runtime_version="explicit device"
    return
  fi

  local runtime_json runtime_id device_json sort_expression
  runtime_json="$(xcrun simctl list runtimes -j)"

  if [[ "$runtime_policy" == "latest" ]]; then
    sort_expression="last"
  else
    sort_expression="first"
  fi

  runtime_id="$(jq -r --arg minimum "$minimum_os" --arg pick "$sort_expression" '
    [
      .runtimes[]
      | select(.isAvailable == true)
      | select(.identifier | contains(".iOS-"))
      | select(
          (.version | split(".") | map(tonumber))
          >= ($minimum | split(".") | map(tonumber))
        )
    ]
    | sort_by(.version | split(".") | map(tonumber))
    | if $pick == "last" then last.identifier else first.identifier end
    // empty
  ' <<<"$runtime_json")"

  if [[ -z "$runtime_id" ]]; then
    echo "error: no available iOS simulator runtime satisfies iOS $minimum_os+" >&2
    echo "Install one in Xcode Settings > Components." >&2
    exit 1
  fi

  runtime_version="$(jq -r --arg id "$runtime_id" '
    [.runtimes[] | select(.identifier == $id)] | first.version
  ' <<<"$runtime_json")"

  device_json="$(xcrun simctl list devices available -j)"
  simulator_id="$(jq -r --arg runtime "$runtime_id" --arg preferred "$preferred_name" '
    (.devices[$runtime] // []) as $devices
    | [
        ($devices[] | select(.isAvailable == true and .name == $preferred)),
        ($devices[] | select(.isAvailable == true and (.name | startswith("iPhone"))))
      ]
    | first.udid // empty
  ' <<<"$device_json")"

  if [[ -z "$simulator_id" ]]; then
    echo "error: no available iPhone simulator exists for iOS $runtime_version" >&2
    exit 1
  fi

  simulator_name="$(jq -r --arg runtime "$runtime_id" --arg id "$simulator_id" '
    [.devices[$runtime][] | select(.udid == $id)] | first.name
  ' <<<"$device_json")"
}

run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    NSUnbufferedIO=YES xcodebuild "$@" 2>&1 | xcbeautify
  else
    xcodebuild "$@"
  fi
}

choose_simulator

if [[ "$action" == "doctor" ]]; then
  developer_dir="$(xcode-select -p)"
  xcode_version="$(xcodebuild -version | paste -sd ' ' -)"
  swift_version="$(xcrun swift --version 2>&1 | grep -m 1 'Apple Swift version')"
  xcode_major="$(xcodebuild -version | head -n 1 | sed -E 's/Xcode ([0-9]+).*/\1/')"

  echo "Developer directory: $developer_dir"
  echo "Xcode: $xcode_version"
  echo "Swift: $swift_version"
  echo "Default simulator: $simulator_name ($runtime_version, $simulator_id)"
  echo "Build output: $derived_data"
  if command -v xcbeautify >/dev/null 2>&1; then
    echo "Output formatter: $(xcbeautify --version)"
  else
    echo "Output formatter: not installed (optional: brew install xcbeautify)"
  fi

  if (( xcode_major < 26 )); then
    echo "error: Hearful requires Xcode 26 or newer" >&2
    exit 1
  fi
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null; then
    echo "error: Xcode first-launch setup is incomplete; run 'sudo xcodebuild -runFirstLaunch'" >&2
    exit 1
  fi
  echo "iOS toolchain is ready."
  exit 0
fi

mkdir -p "$derived_data"
echo "Using $simulator_name on iOS $runtime_version"

common_args=(
  -project "$project"
  -scheme "$scheme"
  -configuration Debug
  -destination "platform=iOS Simulator,id=$simulator_id"
  -derivedDataPath "$derived_data"
)

if [[ "$action" == "build" ]]; then
  run_xcodebuild build "${common_args[@]}"
else
  run_xcodebuild test "${common_args[@]}"
fi
