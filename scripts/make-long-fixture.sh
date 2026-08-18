#!/bin/bash
# Builds an hour-plus recording from the short conversation fixture, for the
# long-meeting live test. Repeats the conversation with varying gaps so chunk
# boundaries have real pauses to find.
#
# Usage: scripts/make-long-fixture.sh <fixture-directory> [minutes]
set -euo pipefail
DIR="${1:?usage: make-long-fixture.sh <fixture-directory> [minutes]}"
MINUTES="${2:-65}"
test -f "$DIR/conversation.wav" || { echo "run make-live-fixture.sh first" >&2; exit 1; }

python3 - "$DIR" "$MINUTES" <<'PY'
import sys, wave, os

directory, minutes = sys.argv[1], float(sys.argv[2])
source = os.path.join(directory, 'conversation.wav')
target_seconds = minutes * 60

with wave.open(source, 'rb') as src:
    rate = src.getframerate()
    frames = src.readframes(src.getnframes())
    seconds = src.getnframes() / rate

out_path = os.path.join(directory, 'long.wav')
with wave.open(out_path, 'wb') as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    total = 0.0
    index = 0
    while total < target_seconds:
        out.writeframes(frames)
        total += seconds
        # Gaps of 0.5 to 3.5 s give the chunk planner genuine pauses to cut at.
        gap = 0.5 + (index % 7) * 0.5
        out.writeframes(b'\x00\x00' * int(gap * rate))
        total += gap
        index += 1

print(f"{out_path}: {total/60:.1f} minutes, {index} repetitions")
PY
