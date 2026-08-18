#!/bin/bash
# Builds a three-speaker conversation for the opt-in live OpenAI tests.
#
# Speech is synthesised locally with `say`, so the fixture costs nothing and is
# reproducible. Only the transcription and diarization requests hit the API.
#
# Usage: scripts/make-live-fixture.sh [output-directory]
set -euo pipefail

OUT_DIR="${1:-${TMPDIR:-/tmp}/meettape-live-fixture}"
mkdir -p "$OUT_DIR"
WORK="$OUT_DIR/turns"
rm -rf "$WORK"
mkdir -p "$WORK"

# Andrew is the local user, so his lines become the microphone track. Chris and
# Tim are remote, and both introduce themselves: speaker resolution is meant to
# find them from exactly that kind of evidence.
say_turn() {
    local index="$1" voice="$2" speaker="$3" text="$4"
    local file
    file="$(printf "%s/%02d_%s.aiff" "$WORK" "$index" "$speaker")"
    say -v "$voice" -r 180 -o "$file" "$text"
    echo "$file"
}

turns=(
    "Alex|Andrew|Morning. Before we start, did the staging cut over finish last night?"
    "Daniel|Chris|Hey Andrew, Chris here. It finished at about two in the morning, and the read replicas are still catching up."
    "Fred|Tim|This is Tim from the platform side. Two seconds of replication lag is fine for us, but we need Frankfurt provisioned before production moves."
    "Alex|Andrew|Agreed. Tim, can your team have Frankfurt ready by the twentieth?"
    "Fred|Tim|The twentieth is tight. I would say the twenty third is realistic, assuming the capacity request clears."
    "Daniel|Chris|Works for me. One more thing: who is owning the rollback runbook?"
    "Alex|Andrew|I will take the runbook. Let us grab time tomorrow morning and walk through it."
)

index=0
files=()
for turn in "${turns[@]}"; do
    IFS='|' read -r voice speaker text <<< "$turn"
    index=$((index + 1))
    files+=("$(say_turn "$index" "$voice" "$speaker" "$text")")
done

# Concatenate everything into one 16 kHz mono WAV, which is what the transcription
# models work at internally.
LIST="$WORK/list.txt"
: > "$LIST"
for file in "${files[@]}"; do echo "$file" >> "$LIST"; done

python3 - "$OUT_DIR" "$LIST" <<'PY'
import subprocess, sys, wave, struct, os

out_dir, list_path = sys.argv[1], sys.argv[2]
files = [line.strip() for line in open(list_path) if line.strip()]

converted = []
for path in files:
    wav = path.replace('.aiff', '.wav')
    subprocess.run(
        ['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', path, wav],
        check=True, capture_output=True,
    )
    converted.append(wav)

gap_frames = int(0.25 * 16000)
gap = b'\x00\x00' * gap_frames

full = os.path.join(out_dir, 'conversation.wav')
mic = os.path.join(out_dir, 'conversation.mic.wav')
remote = os.path.join(out_dir, 'conversation.remote.wav')

truth = []
position = 0.0
full_frames, mic_frames, remote_frames = [], [], []

for path in converted:
    speaker = os.path.basename(path).split('_')[1].split('.')[0]
    with wave.open(path, 'rb') as source:
        frames = source.readframes(source.getnframes())
        seconds = source.getnframes() / source.getframerate()
    silence = b'\x00\x00' * int(seconds * 16000)
    full_frames.append(frames)
    # Each track carries its own speech and silence everywhere else, which is
    # what two separate capture sources actually produce.
    if speaker == 'Andrew':
        mic_frames.append(frames)
        remote_frames.append(silence)
    else:
        mic_frames.append(silence)
        remote_frames.append(frames)
    truth.append({'speaker': speaker, 'start': round(position, 3), 'end': round(position + seconds, 3)})
    position += seconds
    for bucket in (full_frames, mic_frames, remote_frames):
        bucket.append(gap)
    position += 0.25

def write(path, buckets):
    with wave.open(path, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(b''.join(buckets))

write(full, full_frames)
write(mic, mic_frames)
write(remote, remote_frames)

import json
json.dump(truth, open(os.path.join(out_dir, 'truth.json'), 'w'), indent=1)
print(f"conversation: {position:.1f}s across {len(truth)} turns")
print(full)
print(mic)
print(remote)
PY

echo "fixture ready in $OUT_DIR"
