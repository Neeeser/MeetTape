#!/bin/bash
# Canonical build. Usage: scripts/build.sh [debug|release]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
CONFIG="${1:-debug}"
cd "$REPO_ROOT"
swift build --configuration "$CONFIG" "${MEETTAPE_SWIFT_FLAGS[@]+"${MEETTAPE_SWIFT_FLAGS[@]}"}" "${@:2}"
