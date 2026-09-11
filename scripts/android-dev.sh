#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in
    Darwin) default_sdk="$HOME/Library/Android/sdk" ;;
    *) default_sdk="$HOME/Android/Sdk" ;;
esac
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$default_sdk}}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$root/build/android-gradle}"
if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
    export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
fi
adb="$ANDROID_HOME/platform-tools/adb"
package=com.henrydashwood.magpie.dev
artifacts="$root/build/android-artifacts"

fail() { echo "$*" >&2; exit 2; }
require_adb() {
    [[ -x "$adb" ]] || fail "Missing $adb. Install platform-tools or set ANDROID_HOME."
}
android_cli() {
    local cli
    cli="${ANDROID_CLI:-$(command -v android || true)}"
    [[ -n "$cli" ]] || cli="$HOME/.local/bin/android"
    [[ -x "$cli" ]] || fail 'Install the official Android CLI; see android/README.md.'
    "$cli" --sdk="$ANDROID_HOME" "$@"
}

gradle() { "$root/android/gradlew" -p "$root/android" --console=plain "$@"; }
select_emulator() {
    require_adb
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        [[ "$ANDROID_SERIAL" =~ ^emulator-[0-9]+$ ]] || fail 'These preview commands only target emulators. Use Android Studio for an intentional physical-device install.'
        [[ "$("$adb" -s "$ANDROID_SERIAL" get-state)" == device ]] || fail "Emulator $ANDROID_SERIAL is not online."
    else
        local devices
        devices=$("$adb" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1}')
        [[ -n "$devices" && "$devices" != *$'\n'* ]] || fail 'Start one emulator with make android-emulator, or select one with ANDROID_SERIAL=emulator-5554.'
        export ANDROID_SERIAL="$devices"
    fi
    [[ "$("$adb" -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || fail 'The emulator is still booting. Wait for boot to finish and retry.'
}

case "${1:-doctor}" in
    doctor)
        echo 'Launcher Java (Gradle uses its separate Java 21 daemon criteria):'
        "${JAVA_HOME:+$JAVA_HOME/bin/}java" -version
        echo "Android SDK: $ANDROID_HOME"
        for required in platforms/android-37.0/android.jar build-tools/36.0.0/aapt2 platform-tools/adb; do
            [[ -f "$ANDROID_HOME/$required" ]] || fail "Missing $required. See the SDK setup in android/README.md."
        done
        echo "Gradle cache: $GRADLE_USER_HOME"
        gradle --version
        if command -v android >/dev/null || [[ -x "${ANDROID_CLI:-$HOME/.local/bin/android}" ]]; then
            android_cli --version
        else
            echo 'Optional Android CLI is missing; emulator start and layout inspection need it. See android/README.md.'
        fi
        if [[ -x "$ANDROID_HOME/emulator/emulator" ]]; then
            echo 'Available virtual devices:'
            "$ANDROID_HOME/emulator/emulator" -list-avds
            "$ANDROID_HOME/emulator/emulator" -accel-check
        else
            echo 'No emulator installed; build and JVM tests can still run.'
        fi
        "$adb" devices -l
        echo 'Android build toolchain is ready. A booted emulator is required for android-test and android-run.'
        ;;
    build) gradle assembleDebug ;;
    check) gradle assembleDebug assembleDebugAndroidTest testDebugUnitTest lintDebug ;;
    unit-test)
        args=(testDebugUnitTest)
        [[ -z "${TEST:-}" ]] || args+=(--tests "$TEST")
        gradle "${args[@]}"
        ;;
    emulators) android_cli emulator list ;;
    emulator)
        avd="${ANDROID_AVD:-}"
        if [[ -z "$avd" ]]; then
            [[ -x "$ANDROID_HOME/emulator/emulator" ]] || fail 'Install the Android emulator; see android/README.md.'
            avd=$("$ANDROID_HOME/emulator/emulator" -list-avds)
            [[ -n "$avd" && "$avd" != *$'\n'* ]] || fail 'Choose an AVD with ANDROID_AVD=name make android-emulator; list them with make android-emulators.'
        fi
        android_cli emulator start "$avd"
        ;;
    test)
        select_emulator
        args=(connectedDebugAndroidTest)
        [[ -z "${TEST:-}" ]] || args+=("-Pandroid.testInstrumentationRunnerArguments.class=$TEST")
        # Restrict connected tests to the selected emulator, including when a phone is attached.
        ANDROID_SERIAL="$ANDROID_SERIAL" gradle "${args[@]}"
        ;;
    run)
        select_emulator
        gradle assembleDebug
        "$adb" -s "$ANDROID_SERIAL" install -r "$root/android/app/build/outputs/apk/debug/app-debug.apk"
        "$adb" -s "$ANDROID_SERIAL" shell am start -W -n "$package/com.henrydashwood.magpie.MainActivity"
        ;;
    screenshot)
        select_emulator
        mkdir -p "$artifacts"
        output="$artifacts/screen-$ANDROID_SERIAL-$(date +%Y%m%d-%H%M%S)-$$.png"
        "$adb" -s "$ANDROID_SERIAL" exec-out screencap -p > "$output"
        echo "$output"
        ;;
    layout)
        select_emulator
        android_cli layout --device="$ANDROID_SERIAL" --pretty
        ;;
    logs)
        select_emulator
        pid=$("$adb" -s "$ANDROID_SERIAL" shell pidof -s "$package" | tr -d '\r') || fail 'Magpie is not running. Use make android-run first; for crashes use adb logcat -b crash -d.'
        [[ "$pid" =~ ^[0-9]+$ ]] || fail 'Could not find the running Magpie process.'
        mkdir -p "$artifacts"
        output="$artifacts/logcat-$ANDROID_SERIAL-$(date +%Y%m%d-%H%M%S)-$$.txt"
        "$adb" -s "$ANDROID_SERIAL" logcat -d --pid="$pid" > "$output"
        echo "$output"
        ;;
    cli) shift; android_cli "$@" ;;
    *) fail 'Usage: scripts/android-dev.sh {doctor|build|check|unit-test|emulators|emulator|test|run|screenshot|layout|logs|cli ...}' ;;
esac
