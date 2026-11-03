#!/usr/bin/env bash
# The natural voice's Apple-hosted asset pack, and a local server for testing it.
#
#   scripts/voice-pack.sh package <voice folder>
#       build/voice-pack/hearful-natural-voice-v1.aar from the folder text-to-speech notebook 107's voice_folder("ios")
#       makes. For the simulator, make it with simulator=True: the simulator's Core ML won't load the shared-weight
#       body, so that folder also has one per size.
#   scripts/voice-pack.sh tls <simulator udid>
#       Makes a development certificate authority and a localhost certificate under build/voice-pack/tls, has the
#       simulator trust the authority, and imports the localhost identity into the login keychain for ba-serve.
#   scripts/voice-pack.sh serve [port]
#       Apple's mock server for that archive on localhost.
#   scripts/voice-pack.sh point <simulator udid> [port]
#       Points a simulator's development builds at the mock server.
#   scripts/voice-pack.sh android <voice folder>
#       Copies the folder voice_folder("android") makes into Android's on-demand asset pack, which app bundles then
#       carry. Without it, Android builds leave the pack out and the app says the voice isn't available yet.
#
# TestFlight and App Store builds download the copy uploaded to App Store Connect, never this one.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/voice-pack"
archive="$out/hearful-natural-voice-v1.aar"

package() {
  local source="$1"
  [[ -f "$source/voice.json" ]] || { echo "$source isn't a voice folder: no voice.json" >&2; exit 1; }
  rm -rf "$out/NaturalVoice" && mkdir -p "$out"
  ditto "$source" "$out/NaturalVoice"
  rm -f "$archive"
  xcrun ba-package package "$root/background-assets/natural-voice/Manifest.json" --output-path "$archive" --quiet
  du -sh "$archive"
}

android() {
  local source="$1" assets="$root/android/natural_voice/src/main/assets"
  [[ -f "$source/voice.json" && -f "$source/body.tflite" ]] || { echo "$source isn't an Android voice folder" >&2; exit 1; }
  rm -rf "$assets/NaturalVoice" && mkdir -p "$assets"
  cp -R "$source" "$assets/NaturalVoice"
  du -sh "$assets/NaturalVoice"
}

tls() {
  local udid="$1" dir="$out/tls"
  mkdir -p "$dir"
  if [[ ! -f "$dir/localhost.p12" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=Magpie development voice server CA" \
      -keyout "$dir/ca.key" -out "$dir/ca.pem" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout "$dir/localhost.key" -out "$dir/localhost.csr" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' >"$dir/ext.cnf"
    openssl x509 -req -in "$dir/localhost.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -days 825 \
      -extfile "$dir/ext.cnf" -out "$dir/localhost.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$dir/localhost.key" -in "$dir/localhost.pem" -passout pass:magpie \
      -out "$dir/localhost.p12"
  fi
  xcrun simctl keychain "$udid" add-root-cert "$dir/ca.pem"
  security import "$dir/localhost.p12" -P magpie -T /Applications/Xcode.app/Contents/Developer/usr/bin/ba-serve
}

serve() {
  xcrun ba-serve serve "$archive" --host localhost --port "${1:-59024}" --choose-identity-automatically
}

point() {
  local udid="$1" port="${2:-59024}" export
  # ba-serve writes the override to this Mac's defaults; copy it into the simulator's, then clear it here.
  export="$(mktemp)"
  xcrun ba-serve url-override "https://localhost:$port" --quiet
  defaults export com.apple.backgroundassets.managed "$export"
  xcrun ba-serve url-override --clear --quiet
  xcrun simctl spawn "$udid" defaults import com.apple.backgroundassets.managed "$export"
  rm -f "$export"
}

case "${1:-}" in
  package) package "${2:?voice folder}" ;;
  android) android "${2:?voice folder}" ;;
  tls) tls "${2:?simulator udid}" ;;
  serve) serve "${2:-}" ;;
  point) point "${2:?simulator udid}" "${3:-}" ;;
  *) echo "usage: $0 package <voice folder> | tls <udid> | serve [port] | point <udid> [port] | android <voice folder>" >&2; exit 2 ;;
esac
