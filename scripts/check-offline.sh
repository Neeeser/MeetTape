#!/bin/bash
# Runs the ordinary suite and fails if it reaches the network for a model.
#
# The on-device suites are opt-in behind PIPIT_LOCAL_MODELS=1, so a plain
# `scripts/test.sh` must download nothing. A test that constructs a real
# PipitRuntime, SetupModel or LocalModelManager can start an install from a
# detached Task, which the runner neither waits for nor reports: the only
# visible trace is FluidAudio's own log and whatever bytes land on disk. This
# reads both.
#
# Usage: scripts/check-offline.sh [args passed to scripts/test.sh]

# No `set -e`: the suite's exit status is analysed below, not a reason to abort.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ "${PIPIT_LOCAL_MODELS:-}" = "1" ] || [ "${PIPIT_LIVE_OPENAI:-}" = "1" ]; then
    echo "check-offline: refusing to run with PIPIT_LOCAL_MODELS or PIPIT_LIVE_OPENAI set, since those suites download on purpose" >&2
    exit 2
fi

log="$(mktemp -t pipit-offline-check)"
before="$(mktemp -t pipit-offline-before)"
after="$(mktemp -t pipit-offline-after)"
trap 'rm -f "$log" "$before" "$after"' EXIT

temp_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
find "$temp_root" -maxdepth 1 -name 'pipit-tests-*' 2>/dev/null | sort > "$before"

./scripts/test.sh "$@" 2>&1 | tee "$log"
suite_status=${PIPESTATUS[0]}

# Only FluidAudio's fetches are detectable here: its AppLogger mirrors every
# line to stderr. argmax-oss-swift 1.1.0 logs through os.Logger, so WhisperKit's
# downloads go to the unified log at Pipit's .error level and never reach
# stdout or stderr. The detectable half is the half that matters: FluidAudio's
# diarizer and aligner are in every required model set, cloud included.
#
# Match download events, not the category: the same category logs cache hits
# ("Found X locally, no download needed") and compilation.
downloads="$(grep -E 'Downloading .* from HuggingFace|files to download' "$log" || true)"

find "$temp_root" -maxdepth 1 -name 'pipit-tests-*' 2>/dev/null | sort > "$after"
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
