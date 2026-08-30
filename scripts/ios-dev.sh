#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/ios/Hearful.xcodeproj"
scheme="Hearful"
derived_data="${IOS_DERIVED_DATA_PATH:-$repo_root/build/DerivedData}"
minimum_os="${IOS_MINIMUM_OS:-26.0}"
preferred_name="${IOS_SIMULATOR_NAME:-iPhone 17}"
device_derived_data="${IOS_DEVICE_DERIVED_DATA_PATH:-$repo_root/build/Device}"
bundle_id="com.henrydashwood.hearful"
device_api_url="${IOS_DEVICE_API_URL:-https://audio-reader-production.up.railway.app}"

usage() {
  echo "Usage: $0 {doctor|build|index|test|test-latest|device}"
  echo
  echo "Overrides: IOS_SIMULATOR_ID, IOS_SIMULATOR_NAME, IOS_MINIMUM_OS, IOS_DERIVED_DATA_PATH"
  echo "           IOS_DEVICE_ID, IOS_DEVICE_API_URL, IOS_DEVICE_DERIVED_DATA_PATH, IOS_DEVICE_DRY_RUN"
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

if [[ "$action" != "doctor" && "$action" != "build" && "$action" != "index" && "$action" != "test" && "$action" != "device" ]]; then
  usage >&2
  exit 2
fi

require xcodebuild
require xcrun
require jq
if [[ "$action" == "index" ]]; then
  require xcode-build-server
fi

simulator_id="${IOS_SIMULATOR_ID:-}"
runtime_version=""
simulator_name=""

run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    NSUnbufferedIO=YES xcodebuild "$@" 2>&1 | xcbeautify
  else
    xcodebuild "$@"
  fi
}

choose_device() {
  local inventory matches count requested
  requested="${IOS_DEVICE_ID:-}"
  inventory="$(
    xcrun devicectl list devices --quiet --json-output - --omit-deprecated-fields-in-json
  )"
  matches="$(jq --arg requested "$requested" '
    [
      .result.devices[]
      | select(.properties.hardware.reality == "physical")
      | select(.properties.hardware.deviceType == "iPhone")
      | select(.properties.connection.pairingState == "paired")
      | select(
          $requested == ""
          or .identifier == $requested
          or .properties.hardware.udid == $requested
        )
    ]
  ' <<<"$inventory")"
  count="$(jq 'length' <<<"$matches")"

  if [[ "$count" -eq 0 ]]; then
    if [[ -n "$requested" ]]; then
      echo "error: IOS_DEVICE_ID '$requested' is not a paired physical iPhone" >&2
    else
      echo "error: no paired physical iPhone is visible" >&2
    fi
    echo "Unlock the phone, keep it on this Mac's network, and check Xcode > Window > Devices and Simulators." >&2
    exit 1
  fi

  if [[ "$count" -gt 1 ]]; then
    echo "error: more than one paired physical iPhone is visible; choose one with IOS_DEVICE_ID:" >&2
    jq -r '.[] | "  \(.properties.state.name): \(.properties.hardware.udid // .identifier)"' <<<"$matches" >&2
    exit 1
  fi

  device_id="$(jq -r '.[0].properties.hardware.udid // .[0].identifier' <<<"$matches")"
  device_name="$(jq -r '.[0].properties.state.name // .[0].properties.hardware.marketingName' <<<"$matches")"
  device_os="$(jq -r '.[0].properties.software.osVersionNumber.stringValue // "unknown"' <<<"$matches")"
}

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

if [[ "$action" == "device" ]]; then
  choose_device
  app_path="$device_derived_data/Build/Products/Release-iphoneos/Magpie.app"

  echo "Using $device_name on iOS $device_os ($device_id)"
  echo "Release app: $app_path"
  echo "API: $device_api_url"

  if [[ "${IOS_DEVICE_DRY_RUN:-0}" == "1" ]]; then
    echo "Dry run only; nothing was built, installed, or launched."
    exit 0
  fi

  mkdir -p "$device_derived_data"
  # The speech-model removal changed the package graph. Clean this
  # dedicated device DerivedData directory before building so modules from the
  # old package graph cannot be rediscovered as current dependencies. This
  # affects generated build products only, never the installed app or its data.
  run_xcodebuild clean build \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "platform=iOS,id=$device_id" \
    -derivedDataPath "$device_derived_data" \
    -allowProvisioningUpdates

  if [[ ! -d "$app_path" ]]; then
    echo "error: Release app was not produced at '$app_path'" >&2
    exit 1
  fi

  # Install over the existing copy. Never uninstall here: doing so clears the
  # app's data, developer trust, and Local Network permission on the phone.
  xcrun devicectl device install app --device "$device_id" "$app_path"
  launch_environment="$(jq -cn --arg url "$device_api_url" '{HEARFUL_API_URL: $url}')"
  xcrun devicectl device process launch \
    --device "$device_id" \
    --terminate-existing \
    --environment-variables "$launch_environment" \
    "$bundle_id"
  exit 0
fi

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
elif [[ "$action" == "index" ]]; then
  index_log="$repo_root/build/xcodebuild-index.log"
  echo "Refreshing SourceKit-LSP build settings"
  # The build server needs a complete, unformatted xcodebuild log. A clean
  # build-for-testing covers both app and test sources and replaces stale
  # compile flags when files or settings are removed.
  NSUnbufferedIO=YES xcodebuild clean build-for-testing "${common_args[@]}" 2>&1 \
    | tee "$index_log" \
    | (cd "$repo_root" && xcode-build-server parse -v -v)
  echo "Build-server config: $repo_root/buildServer.json"
  echo "Build log: $index_log"
else
  run_xcodebuild test "${common_args[@]}"
fi
