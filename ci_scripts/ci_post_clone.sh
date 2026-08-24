#!/usr/bin/env bash

set -euo pipefail

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
"$repo_root/scripts/bootstrap-kokoro-packages.sh"
