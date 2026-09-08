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
device_api_url="${IOS_DEVICE_API_URL:-https://audio-reader-staging.up.railway.app}"

usage() {
  echo "Usage: $0 {doctor|build|index|test|test-latest|device|device-local}"
  echo
  echo "Overrides: IOS_SIMULATOR_ID, IOS_SIMULATOR_NAME, IOS_MINIMUM_OS, IOS_DERIVED_DATA_PATH"
  echo "           IOS_INDEX_DERIVED_DATA_PATH, TEST (suite or suite/test identifier)"
  echo "           IOS_TEST_PREBOOT=1 (overlap boot/build and report phase timings)"
  echo "           IOS_COMPILATION_CACHE=1 (enable Xcode compilation caching)"
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
local_device_build=0
if [[ "$action" == "test-latest" ]]; then
  runtime_policy="latest"
  action="test"
fi

# Index refreshes need a clean build, so give them their own output even when
# the caller overrides the normal build/test directory.
if [[ "$action" == "index" ]]; then
  derived_data="${IOS_INDEX_DERIVED_DATA_PATH:-$repo_root/build/IndexDerivedData}"
fi

if [[ "$action" == "device-local" ]]; then
  local_device_build=1
  if [[ -z "${IOS_DEVICE_API_URL:-}" ]]; then
    require route
    require ifconfig
    default_interface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }' || true)"
    local_ip=""
    for candidate_interface in "$default_interface" en0 en1; do
      [[ -n "$candidate_interface" ]] || continue
      local_ip="$(
        ifconfig "$candidate_interface" 2>/dev/null \
          | awk '$1 == "inet" && $2 !~ /^(127\.|169\.254\.)/ { print $2; exit }'
      )"
      [[ -n "$local_ip" ]] && break
    done
    if [[ -z "$local_ip" ]]; then
      echo "error: could not determine this Mac's LAN address" >&2
      echo "Set IOS_DEVICE_API_URL explicitly, for example:" >&2
      echo "  IOS_DEVICE_API_URL=http://192.168.1.20:8000 make ios-phone-debug" >&2
      exit 1
    fi
    device_api_url="http://$local_ip:8000"
  fi
  action="device"
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

report_timing() {
  local label="$1" elapsed="$2" status="$3"
  echo "Timing: $label: ${elapsed}s (exit $status)"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf -- '- %s: %ss (exit %s)\n' "$label" "$elapsed" "$status" >> "$GITHUB_STEP_SUMMARY"
  fi
}

timed_xcodebuild() {
  local label="$1" started=$SECONDS status=0
  shift
  run_xcodebuild "$@" || status=$?
  report_timing "$label" "$((SECONDS - started))" "$status"
  return "$status"
}

test_with_preboot() (
  local started=$SECONDS boot_started=$SECONDS build_status=0 boot_status=0
  local boot_pid boot_log wait_started
  boot_log="$(mktemp "${TMPDIR:-/tmp}/magpie-simulator-boot.XXXXXX")"

  # bootstatus -b also handles an already booted simulator. Run it directly
  # in the background so cleanup can stop this exact process on build failure.
  xcrun simctl bootstatus "$simulator_id" -b > "$boot_log" 2>&1 &
  boot_pid=$!
  trap 'kill "$boot_pid" 2>/dev/null || true; wait "$boot_pid" 2>/dev/null || true; rm -f "$boot_log"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  timed_xcodebuild "Build for testing" build-for-testing \
    "${common_args[@]}" -showBuildTimingSummary || build_status=$?
  if [[ "$build_status" != 0 ]]; then
    cat "$boot_log"
    return "$build_status"
  fi
  wait_started=$SECONDS
  wait "$boot_pid" || boot_status=$?
  cat "$boot_log"
  report_timing "Simulator wait after build" "$((SECONDS - wait_started))" "$boot_status"
  # bootstatus's own log contains its actual boot elapsed time. This measures
  # the combined readiness interval, since build and boot deliberately overlap.
  report_timing "Build and simulator ready" "$((SECONDS - boot_started))" "$boot_status"
  rm -f "$boot_log"
  trap - EXIT INT TERM
  [[ "$boot_status" == 0 ]] || return "$boot_status"

  local test_status=0
  timed_xcodebuild "Test without building (includes app launch)" \
    test-without-building "${test_args[@]}" || test_status=$?
  report_timing "Total phased test run" "$((SECONDS - started))" "$test_status"
  return "$test_status"
)

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

  device_build_settings=()
  if [[ "$local_device_build" == "1" ]]; then
    require curl
    if ! curl --fail --silent --show-error --max-time 3 "$device_api_url/health" >/dev/null; then
      echo "error: the local backend is not reachable at $device_api_url" >&2
      echo "Run 'make ios-phone-debug' to start it and install the app together." >&2
      exit 1
    fi
    # This condition exists only in the local physical-device build. It keeps
    # the ordinary Release/App Store binary free of development authentication
    # while preserving App Intents, which require a Release device build.
    device_build_settings+=(
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) HEARFUL_LOCAL_DEVICE'
    )
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
    -allowProvisioningUpdates \
    "${device_build_settings[@]}"

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
  # Capture each producer completely before selecting a line from its output.
  # With `pipefail`, `grep -m 1` and `head -n 1` can close their pipe while
  # Xcode is still writing; the resulting SIGPIPE is exit 141 and used to make
  # CI fail in the doctor step before it could print a single diagnostic.
  xcode_output="$(xcodebuild -version)"
  swift_output="$(xcrun swift --version 2>&1)"
  xcode_version="$(paste -sd ' ' - <<<"$xcode_output")"
  swift_version="$(awk '/Apple Swift version/ && !found { print; found=1 }' <<<"$swift_output")"
  xcode_major="$(sed -nE '1s/Xcode ([0-9]+).*/\1/p' <<<"$xcode_output")"

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

if [[ "${IOS_COMPILATION_CACHE:-0}" == "1" ]]; then
  common_args+=(COMPILATION_CACHE_ENABLE_CACHING=YES)
fi

# Keep this array nonempty: macOS's Bash 3.2 treats an empty array as unset
# under nounset, even when expanded with [@].
test_args=("${common_args[@]}")
if [[ "$action" == "test" && -n "${TEST:-}" ]]; then
  test_identifier="$TEST"
  if [[ "$test_identifier" != HearfulTests && "$test_identifier" != HearfulTests/* ]]; then
    test_identifier="HearfulTests/$test_identifier"
  fi
  test_args+=("-only-testing:$test_identifier")
  echo "Testing only: $test_identifier"
fi

if [[ "$action" == "build" ]]; then
  run_xcodebuild build "${common_args[@]}"
elif [[ "$action" == "index" ]]; then
  index_log="$repo_root/build/xcodebuild-index.log"
  mkdir -p "$repo_root/build"
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
  if [[ "${IOS_TEST_PREBOOT:-0}" == "1" ]]; then
    test_with_preboot
  else
    timed_xcodebuild "Build and test" test "${test_args[@]}"
  fi
fi
