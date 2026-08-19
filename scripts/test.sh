#!/bin/bash
# Canonical test run. Usage: scripts/test.sh [--filter Substring] [--list]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
cd "$REPO_ROOT"
swift run --configuration debug "${MEETTAPE_SWIFT_FLAGS[@]+"${MEETTAPE_SWIFT_FLAGS[@]}"}" meettape-test "$@"
