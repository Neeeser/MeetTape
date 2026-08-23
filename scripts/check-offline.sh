#!/bin/bash
# Runs the ordinary suite and fails if it reaches the network for a model.
#
# The on-device suites are opt-in behind MEETTAPE_LOCAL_MODELS=1, so a plain
# `scripts/test.sh` must download nothing. A test that constructs a real
# MeetTapeRuntime, SetupModel or LocalModelManager can start an install from a
# detached Task, which the runner neither waits for nor reports: the only
# visible trace is FluidAudio's own log and whatever bytes land on disk. This
# reads both.
#
# Usage: scripts/check-offline.sh [args passed to scripts/test.sh]
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log="$(mktemp -t meettape-offline-check)"
temp_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
before="$(mktemp -t meettape-offline-before)"
find "$temp_root" -maxdepth 1 -name 'meettape-tests-*' 2>/dev/null | sort > "$before"

./scripts/test.sh "$@" 2>&1 | tee "$log"
suite_status=${PIPESTATUS[0]}

# FluidAudio logs through its own category, and WhisperKit through argmax's.
# Either line means a model fetch began.
downloads="$(grep -E 'DownloadUtils|from HuggingFace|Downloading (Whisper|Parakeet|Cohere)' "$log" || true)"

after="$(mktemp -t meettape-offline-after)"
find "$temp_root" -maxdepth 1 -name 'meettape-tests-*' 2>/dev/null | sort > "$after"
leaked="$(comm -13 "$before" "$after")"

echo
echo "────────────────────────────────────────────────────────────"
if [ -n "$leaked" ]; then
    # Informational: another test run on the same machine lands here too.
    echo "test directories left in $temp_root after the run:"
    while IFS= read -r dir; do
        [ -n "$dir" ] && du -sh "$dir" 2>/dev/null
    done <<< "$leaked"
fi

if [ -n "$downloads" ]; then
    echo "offline check FAILED: the suite started a model download"
    echo "$downloads"
    exit 1
fi

echo "offline check passed: no model download during the run"
exit "$suite_status"
