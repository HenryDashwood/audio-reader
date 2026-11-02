#!/usr/bin/env bash
# Build native/g2p, the downloadable voice's text-to-phonemes library, for the apps.
#
#   scripts/build-g2p.sh ios       native/g2p/build/MagpieG2P.xcframework (device and Apple-silicon simulator)
#   scripts/build-g2p.sh android   android/app/src/main/jniLibs/<abi>/libmagpie_g2p.so (needs the NDK and cargo-ndk)
#
# Rust comes from rustup; RUST_TOOLCHAIN picks the toolchain (edition 2024 needs 1.85 or later).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/native/g2p"
toolchain="${RUST_TOOLCHAIN:-1.97}"
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
  command -v cargo-ndk >/dev/null || { echo "cargo-ndk is missing: cargo install cargo-ndk" >&2; exit 1; }
  rustup target add --toolchain "$toolchain" aarch64-linux-android x86_64-linux-android >/dev/null
  "${cargo[@]}" ndk --manifest-path "$crate/Cargo.toml" -t arm64-v8a -t x86_64 -P 26 \
    -o "$root/android/app/src/main/jniLibs" build --release --lib
}

case "${1:-}" in
  ios) ios ;;
  android) android ;;
  *) echo "usage: $0 ios|android" >&2; exit 2 ;;
esac
