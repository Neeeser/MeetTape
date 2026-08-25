#!/bin/bash
# Developer evaluation tool. Usage: scripts/eval.sh <command> [flags]
#
# Not part of the application. This is how the local stack's measured numbers get
# checked again, on this machine, against audio somebody is allowed to use.
#
#   scripts/eval.sh asr      --audio meeting.wav
#   scripts/eval.sh diarize  --audio meeting.wav --fa 0.07 --fa 0.20
#   scripts/eval.sh identity --audio andrew.wav --audio chris.wav
#   scripts/eval.sh voices
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
cd "$REPO_ROOT"
swift run --configuration release "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" pipit-eval "$@"
