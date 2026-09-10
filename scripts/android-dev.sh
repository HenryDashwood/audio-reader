#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$root/build/android-gradle}"
if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
    export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
fi
adb="$ANDROID_HOME/platform-tools/adb"

gradle() { "$root/android/gradlew" -p "$root/android" --console=plain "$@"; }
select_emulator() {
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        if [[ "$ANDROID_SERIAL" != emulator-* ]]; then
            echo 'These preview commands only install on emulators. Use Android Studio for an intentional physical-device install.' >&2
            exit 2
        fi
        "$adb" -s "$ANDROID_SERIAL" get-state >/dev/null
        return
    fi
    local devices
    devices=$("$adb" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1}')
    if [[ -z "$devices" || "$devices" == *$'\n'* ]]; then
        echo 'Start one emulator in Android Studio, or select one with ANDROID_SERIAL=emulator-5554.' >&2
        exit 2
    fi
    export ANDROID_SERIAL="$devices"
}

case "${1:-doctor}" in
    doctor)
        "${JAVA_HOME:+$JAVA_HOME/bin/}java" -version
        echo "Android SDK: $ANDROID_HOME"
        [[ -d "$ANDROID_HOME/platforms" ]] || { echo 'Install an Android SDK in Android Studio.' >&2; exit 1; }
        ls "$ANDROID_HOME/platforms"
        "$adb" devices
        ;;
    build) gradle assembleDebug ;;
    check) gradle assembleDebug testDebugUnitTest lintDebug ;;
    test)
        select_emulator
        # Restrict connected tests to the selected emulator, including when a phone is attached.
        ANDROID_SERIAL="$ANDROID_SERIAL" gradle connectedDebugAndroidTest
        ;;
    run)
        select_emulator
        gradle assembleDebug
        "$adb" -s "$ANDROID_SERIAL" install -r "$root/android/app/build/outputs/apk/debug/app-debug.apk"
        "$adb" -s "$ANDROID_SERIAL" shell am start -n com.henrydashwood.magpie.dev/com.henrydashwood.magpie.MainActivity
        ;;
    *) echo 'Usage: scripts/android-dev.sh {doctor|build|check|test|run}' >&2; exit 2 ;;
esac
