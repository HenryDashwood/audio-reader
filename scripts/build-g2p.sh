#!/usr/bin/env bash
# Build native/g2p, the downloadable voice's text-to-phonemes library, for the apps.
#
#   scripts/build-g2p.sh ios       native/g2p/build/MagpieG2P.xcframework (device and Apple-silicon simulator)
#   scripts/build-g2p.sh android [dir]   dir/arm64-v8a/libmagpie_g2p.so, default native/g2p/build/jniLibs (Gradle runs this)
#
# Android needs an NDK: ANDROID_NDK_HOME, else the newest under the SDK's ndk/ folder.
#
# Rust comes from rustup; RUST_TOOLCHAIN picks the toolchain (edition 2024 needs 1.85 or later).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/native/g2p"
toolchain="${RUST_TOOLCHAIN:-1.97}"
export PATH="$HOME/.cargo/bin:$PATH"  # Android Studio starts Gradle without the shell's PATH
cargo=(rustup run "$toolchain" cargo)
export CARGO_TARGET_DIR="$crate/build/target"

ios() {
  local targets=(aarch64-apple-ios aarch64-apple-ios-sim)
  rustup target add --toolchain "$toolchain" "${targets[@]}" >/dev/null
  local args=()
  for target in "${targets[@]}"; do
    IPHONEOS_DEPLOYMENT_TARGET=26.0 "${cargo[@]}" build --manifest-path "$crate/Cargo.toml" --release --lib --target "$target"
    local headers="$crate/build/headers/$target"
    rm -rf "$headers" && mkdir -p "$headers"
    cp "$crate/include/magpie_g2p.h" "$headers/"
    printf 'module MagpieG2P {\n    header "magpie_g2p.h"\n    export *\n}\n' >"$headers/module.modulemap"
    args+=(-library "$CARGO_TARGET_DIR/$target/release/libmagpie_g2p.a" -headers "$headers")
  done
  rm -rf "$crate/build/MagpieG2P.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$crate/build/MagpieG2P.xcframework" >/dev/null
  echo "$crate/build/MagpieG2P.xcframework"
}

android() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local ndk="${ANDROID_NDK_HOME:-$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)}"
  [[ -d "$ndk/toolchains/llvm/prebuilt" ]] || { echo "No Android NDK: set ANDROID_NDK_HOME or install one under $sdk/ndk" >&2; exit 1; }
  local bin
  bin="$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)"
  local api=31  # The app's minSdk
  rustup target add --toolchain "$toolchain" aarch64-linux-android >/dev/null
  # The NDK's clang links, which also gives the library the 16 KB page alignment Android 15 needs.
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$bin/aarch64-linux-android$api-clang" \
    "${cargo[@]}" build --manifest-path "$crate/Cargo.toml" --release --lib --target aarch64-linux-android
  local out="${1:-$crate/build/jniLibs}/arm64-v8a"
  mkdir -p "$out"
  cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/libmagpie_g2p.so" "$out/"
  "$bin/llvm-strip" --strip-unneeded "$out/libmagpie_g2p.so"
  echo "$out/libmagpie_g2p.so"
}

case "${1:-}" in
  ios) ios ;;
  android) android "${2:-}" ;;
  *) echo "usage: $0 ios|android" >&2; exit 2 ;;
esac
