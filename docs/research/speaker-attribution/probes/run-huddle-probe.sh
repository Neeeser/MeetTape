#!/bin/bash
# Runs the Slack huddle probe against a recording of the room, so speech and
# accessibility-tree changes land on one clock.
#
# The recording is what makes the timing answerable. The tree says when Slack
# decided somebody is speaking. Only the waveform says when they actually
# started, and the gap between the two is the number we are after.
#
# A beep is played a moment after both are running. It lands in the recording at
# a known epoch, which is what pins the two clocks together.
#
#   ./run-huddle-probe.sh /tmp/huddle-run 105
#
# Delete the audio when the numbers are out. It is a recording of a person.

set -euo pipefail
OUT=${1:-/tmp/huddle-run}
SECONDS_TO_RUN=${2:-105}
mkdir -p "$OUT"

# 3 s of headroom at each end so neither stream clips a transition.
ffmpeg -y -f avfoundation -i ":0" -ac 1 -ar 16000 \
  -t $((SECONDS_TO_RUN + 6)) "$OUT/mic.wav" > "$OUT/ffmpeg.log" 2>&1 &
FF=$!

sleep 3
date +%s.%N > "$OUT/watch_epoch.txt"
/tmp/huddlewatch "$SECONDS_TO_RUN" > "$OUT/watch.log" 2>&1 &
WATCH=$!

# The sync marker. Played after the watcher is up so it appears in both the
# recording and the log's own time base.
sleep 1
python3 - "$OUT/beep.wav" <<'PY'
import math, struct, sys, wave
rate, dur, freq = 16000, 0.15, 1000.0
with wave.open(sys.argv[1], 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(b''.join(
        struct.pack('<h', int(22000 * math.sin(2 * math.pi * freq * i / rate)))
        for i in range(int(rate * dur))))
PY
date +%s.%N > "$OUT/beep_epoch.txt"
afplay "$OUT/beep.wav"

wait $WATCH
wait $FF
echo "done: $OUT"
