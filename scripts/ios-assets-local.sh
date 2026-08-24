#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$repo_root/background-assets/kokoro"
local_root="${HEARFUL_BA_LOCAL_ROOT:-$repo_root/build/BackgroundAssetsLocal}"
tools_root="$local_root/tools"
state_root="$local_root/state"
certificate_root="$local_root/certificates"
output_root="$local_root/output"
archive_name="Hearful-Kokoro-English-v1.aar"
archive_path="$output_root/$archive_name"
tools_zip="${HEARFUL_BA_TOOLS_ZIP:-${HOME}/Downloads/aarch64.zip}"
docker_image="${HEARFUL_BA_DOCKER_IMAGE:-ubuntu:24.04}"
server_port="${HEARFUL_BA_PORT:-60791}"
asset_version="${HEARFUL_BA_VERSION:-$(date +%s)}"
license_file="$state_root/.ba/License.plist"

usage() {
  cat <<'EOF'
Usage: scripts/ios-assets-local.sh {license|setup|package|serve|doctor}

Commands:
  license  Read and accept Apple's Managed Background Assets tools licence.
  setup    Prepare the tools and HTTPS identity, then print the iPhone steps.
  package  Build the local Kokoro .aar when its source files have changed.
  serve    Package if needed and run Apple's HTTPS mock server in the foreground.
  doctor   Check the local tools, certificate, model files, and server address.

Overrides:
  HEARFUL_BA_HOST          Reachable hostname or IP (default: this Mac's .local name)
  HEARFUL_BA_PORT          HTTPS port (default: 60791)
  HEARFUL_BA_VERSION       Mock asset version (default: current Unix timestamp)
  HEARFUL_BA_TOOLS_ZIP     Path to Apple's aarch64.zip developer tools download
  HEARFUL_BA_LOCAL_ROOT    Generated local state (default: build/BackgroundAssetsLocal)
  HEARFUL_BA_FORCE_PACKAGE Set to 1 to rebuild the archive even when up to date
EOF
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' is not installed" >&2
    exit 1
  fi
}

determine_host() {
  if [[ -n "${HEARFUL_BA_HOST:-}" ]]; then
    server_host="$HEARFUL_BA_HOST"
    return
  fi

  local local_name
  local_name="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  if [[ -z "$local_name" ]]; then
    echo "error: could not determine this Mac's network hostname" >&2
    echo "Set HEARFUL_BA_HOST to a hostname or IP that the iPhone can reach." >&2
    exit 1
  fi
  if [[ "$local_name" == *.* ]]; then
    server_host="$local_name"
  else
    server_host="$local_name.local"
  fi
}

validate_settings() {
  if [[ ! "$server_port" =~ ^[0-9]+$ ]] || (( server_port < 1 || server_port > 65535 )); then
    echo "error: HEARFUL_BA_PORT must be a number from 1 to 65535" >&2
    exit 1
  fi
  if [[ ! "$asset_version" =~ ^[0-9]+$ ]]; then
    echo "error: HEARFUL_BA_VERSION must be a non-negative integer" >&2
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "$tools_root" "$state_root/.ba" "$certificate_root" "$output_root"
}

ensure_tools() {
  require docker
  require unzip
  ensure_directories

  if [[ ! -f "$tools_root/ba-package" || ! -f "$tools_root/ba-serve" ]]; then
    if [[ ! -f "$tools_zip" ]]; then
      echo "error: Apple's Managed Background Assets tools were not found at:" >&2
      echo "  $tools_zip" >&2
      echo >&2
      echo "Download aarch64.zip from Apple Developer Downloads, or set" >&2
      echo "HEARFUL_BA_TOOLS_ZIP to its location." >&2
      exit 1
    fi
    unzip -jo "$tools_zip" \
      "Apple Silicon/ba-package" \
      "Apple Silicon/ba-serve" \
      -d "$tools_root" >/dev/null
  fi

  # Apple's zip doesn't preserve the executable bits on every unzip tool.
  chmod +x "$tools_root/ba-package" "$tools_root/ba-serve"
}

run_ba_package() {
  docker run --rm --platform linux/arm64 \
    -v "$tools_root/ba-package:/usr/local/bin/ba-package:ro" \
    -v "$state_root/.ba:/root/.ba" \
    "$docker_image" \
    /usr/local/bin/ba-package "$@"
}

accept_license() {
  ensure_tools
  if [[ -f "$license_file" ]]; then
    echo "Apple's Managed Background Assets tools licence is already accepted."
    return
  fi

  run_ba_package license read
  echo
  read -r -p "Do you agree to this licence? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      run_ba_package license agree
      ;;
    *)
      echo "Licence not accepted; no state was changed."
      exit 1
      ;;
  esac
}

ensure_license() {
  if [[ -f "$license_file" ]]; then
    return
  fi
  echo "error: Apple's Managed Background Assets tools licence is not accepted here." >&2
  echo "Run 'make ios-assets-license' once, then retry." >&2
  exit 1
}

write_root_config() {
  cat >"$certificate_root/root-ca.cnf" <<'EOF'
[req]
distinguished_name = distinguished_name
x509_extensions = v3_ca
prompt = no

[distinguished_name]
CN = Hearful Background Assets Local CA

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
}

write_server_config() {
  local alternative_name
  if [[ "$server_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    alternative_name="IP.1 = $server_host"
  else
    alternative_name="DNS.1 = $server_host"
  fi

  cat >"$certificate_root/server.cnf" <<EOF
[req]
distinguished_name = distinguished_name
req_extensions = v3_server
prompt = no

[distinguished_name]
CN = $server_host

[v3_server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alternative_names

[alternative_names]
$alternative_name
EOF
}

ensure_certificates() {
  require openssl
  ensure_directories
  determine_host

  local root_key="$certificate_root/root-ca-key.pem"
  local root_certificate="$certificate_root/root-ca.pem"
  local phone_certificate="$certificate_root/Hearful-Background-Assets-Local-CA.cer"
  local server_key="$certificate_root/server-key.pem"
  local server_certificate="$certificate_root/server.pem"
  local recorded_host=""

  if [[ -f "$certificate_root/host.txt" ]]; then
    recorded_host="$(<"$certificate_root/host.txt")"
  fi

  if [[ -e "$root_key" || -e "$root_certificate" ]]; then
    if [[ ! -f "$root_key" || ! -f "$root_certificate" ]]; then
      echo "error: the local certificate authority is incomplete in $certificate_root" >&2
      echo "Move that directory aside and run 'make ios-assets-setup' again." >&2
      exit 1
    fi
  else
    echo "Creating a local certificate authority for the iPhone mock server…"
    write_root_config
    openssl genrsa -out "$root_key" 4096 2>/dev/null
    openssl req -x509 -new -key "$root_key" -sha256 -days 3650 \
      -config "$certificate_root/root-ca.cnf" \
      -out "$root_certificate"
    chmod 600 "$root_key"
  fi

  if [[ ! -f "$phone_certificate" ]]; then
    openssl x509 -in "$root_certificate" -outform DER -out "$phone_certificate"
  fi

  if [[ "$recorded_host" != "$server_host" || ! -f "$server_key" || ! -f "$server_certificate" ]]; then
    echo "Creating an HTTPS identity for ${server_host}…"
    write_server_config
    openssl genrsa -out "$server_key" 2048 2>/dev/null
    openssl req -new -key "$server_key" \
      -config "$certificate_root/server.cnf" \
      -out "$certificate_root/server.csr"
    openssl x509 -req \
      -in "$certificate_root/server.csr" \
      -CA "$root_certificate" \
      -CAkey "$root_key" \
      -CAcreateserial \
      -days 825 \
      -sha256 \
      -extfile "$certificate_root/server.cnf" \
      -extensions v3_server \
      -out "$server_certificate" >/dev/null
    chmod 600 "$server_key"
    printf '%s\n' "$server_host" >"$certificate_root/host.txt"
  fi
}

check_model_files() {
  local missing=0
  for path in \
    "$source_root/Manifest.json" \
    "$source_root/Kokoro/kokoro-v1_0.safetensors" \
    "$source_root/Kokoro/voices.npz"
  do
    if [[ ! -f "$path" ]]; then
      echo "error: required asset-pack source is missing: $path" >&2
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi
}

archive_is_current() {
  if [[ ! -f "$archive_path" ]]; then
    return 1
  fi
  if [[ "${HEARFUL_BA_FORCE_PACKAGE:-0}" == "1" ]]; then
    return 1
  fi
  [[ "$archive_path" -nt "$source_root/Manifest.json" \
    && "$archive_path" -nt "$source_root/Kokoro/kokoro-v1_0.safetensors" \
    && "$archive_path" -nt "$source_root/Kokoro/voices.npz" ]]
}

package_assets() {
  ensure_tools
  ensure_license
  check_model_files
  ensure_directories

  if archive_is_current; then
    echo "Asset pack is up to date: $archive_path"
    return
  fi

  local temporary_name=".$$.${archive_name}"
  local temporary_path="$output_root/$temporary_name"
  rm -f "$temporary_path"

  echo "Packaging the Kokoro asset pack…"
  if ! docker run --rm --platform linux/arm64 \
    -v "$tools_root/ba-package:/usr/local/bin/ba-package:ro" \
    -v "$state_root/.ba:/root/.ba" \
    -v "$source_root:/input:ro" \
    -v "$output_root:/output" \
    -w /input \
    "$docker_image" \
    /usr/local/bin/ba-package package Manifest.json -o "/output/$temporary_name"
  then
    rm -f "$temporary_path"
    return 1
  fi

  mv -f "$temporary_path" "$archive_path"
  echo "Asset pack ready: $archive_path"
  shasum -a 256 "$archive_path"
}

print_phone_setup() {
  determine_host
  cat <<EOF

One-time iPhone setup
---------------------
1. Send this certificate to the iPhone and install the downloaded profile:
   $certificate_root/Hearful-Background-Assets-Local-CA.cer
2. On the iPhone, enable it under:
   Settings > General > About > Certificate Trust Settings
3. With Developer Mode enabled, open:
   Settings > Developer > Background Assets Testing > Development Overrides
4. Set URL Override to:
   https://$server_host:$server_port

Keep the serving terminal open while downloading the natural voice.
EOF
}

setup_local_assets() {
  ensure_tools
  ensure_certificates
  print_phone_setup
  if [[ ! -f "$license_file" ]]; then
    echo
    echo "Before packaging, run: make ios-assets-license"
  fi
}

serve_assets() {
  ensure_tools
  ensure_license
  ensure_certificates
  package_assets
  print_phone_setup

  echo
  echo "Serving $archive_name as local version $asset_version"
  echo "Press Control-C to stop."
  docker run --rm --init --platform linux/arm64 \
    -p "$server_port:$server_port" \
    -v "$tools_root/ba-serve:/usr/local/bin/ba-serve:ro" \
    -v "$state_root/.ba:/root/.ba" \
    -v "$archive_path:/assets/$archive_name:ro" \
    -v "$certificate_root:/certificates:ro" \
    "$docker_image" \
    /usr/local/bin/ba-serve serve "/assets/$archive_name" \
      --asset-pack-versions "$asset_version" \
      --host "$server_host" \
      --port "$server_port" \
      --identity-path /certificates/server.pem \
      --identity-path /certificates/server-key.pem
}

doctor() {
  ensure_tools
  ensure_certificates
  validate_settings
  check_model_files
  determine_host

  echo "Background Assets local development"
  echo "Tools: $tools_root"
  echo "Tool version: $(run_ba_package --version)"
  echo "Licence: $([[ -f "$license_file" ]] && echo accepted || echo not accepted)"
  echo "Source: $source_root"
  echo "Archive: $archive_path"
  echo "Certificate: $certificate_root/Hearful-Background-Assets-Local-CA.cer"
  echo "URL override: https://$server_host:$server_port"
}

action="${1:-}"
validate_settings

case "$action" in
  license)
    accept_license
    ;;
  setup)
    setup_local_assets
    ;;
  package)
    package_assets
    ;;
  serve)
    serve_assets
    ;;
  doctor)
    doctor
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
