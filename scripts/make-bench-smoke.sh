#!/bin/bash
# Builds the free two-voice fixture the benchmark smoke tier runs against.
#
# Speech is synthesised locally with `say`, so this costs nothing, needs no
# network and runs anywhere. It catches wiring, chunk-seam and assembly defects
# rather than accuracy: the reference words are exactly what was spoken, and
# word timings are spread evenly across each turn because `say` reports none.
#
# Usage: scripts/make-bench-smoke.sh [output-directory]
set -euo pipefail

OUT_DIR="${1:-${TMPDIR:-/tmp}/pipit-bench-smoke}"
mkdir -p "$OUT_DIR"
WORK="$OUT_DIR/turns"
rm -rf "$WORK"
mkdir -p "$WORK"

# Two voices, distinct enough that a diarizer separating them is doing real
# work: one male, one female, alternating throughout.
turns=(
    "Daniel|SMOKE_A|Right, let us start with the release. The staging cut over finished at two in the morning."
    "Karen|SMOKE_B|Good. Did the read replicas catch up, or are we still seeing lag on the reporting queries?"
    "Daniel|SMOKE_A|About two seconds of lag at the peak, and it settled within the hour. Nothing on the reporting side broke."
    "Karen|SMOKE_B|Then the only open question is Frankfurt. Capacity has not cleared and the request went in last Tuesday."
    "Daniel|SMOKE_A|I will chase the capacity request today. If it clears by Thursday we can provision over the weekend."
    "Karen|SMOKE_B|Put the twenty third on the plan, not the twentieth. I would rather move once than move twice."
    "Daniel|SMOKE_A|Agreed, the twenty third. I will also write the rollback runbook and send it round before Friday."
    "Karen|SMOKE_B|Send it to the platform list as well. They own the database failover and they should read it first."
    "Daniel|SMOKE_A|Will do. The other thing is the migration script, which still takes eleven minutes on the largest tenant."
    "Karen|SMOKE_B|Eleven minutes of write lock is too long. Can it run in batches, or does it need the whole table at once?"
    "Daniel|SMOKE_A|Batches work. I tested a thousand rows at a time on a copy and it finished in under two minutes."
    "Karen|SMOKE_B|Then do that, and add a progress log so we can tell the difference between slow and stuck."
    "Daniel|SMOKE_A|Fair. Last item, the on call rotation over the holiday. Two people have already asked to swap weeks."
    "Karen|SMOKE_B|Let them swap, as long as somebody senior is on each week. Post the final rotation by Friday."
    "Daniel|SMOKE_A|Friday works. I will send the rotation, the runbook and the migration plan in one message."
    "Karen|SMOKE_B|One message is better than three. Thanks, that is everything from me for this week."
)

index=0
: > "$WORK/list.txt"
for turn in "${turns[@]}"; do
    IFS='|' read -r voice speaker text <<< "$turn"
    index=$((index + 1))
    file="$(printf "%s/%02d_%s.aiff" "$WORK" "$index" "$speaker")"
    say -v "$voice" -r 175 -o "$file" "$text"
    printf "%s\t%s\t%s\n" "$file" "$speaker" "$text" >> "$WORK/list.txt"
done

python3 - "$OUT_DIR" "$WORK/list.txt" <<'PY'
import json, os, subprocess, sys, wave

out_dir, list_path = sys.argv[1], sys.argv[2]
rows = [line.rstrip("\n").split("\t") for line in open(list_path) if line.strip()]

gap = 0.4
rate = 16000
frames = []
words = []
turns = []
position = 0.0

for path, speaker, text in rows:
    wav = path.replace(".aiff", ".wav")
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, wav],
        check=True, capture_output=True,
    )
    with wave.open(wav, "rb") as source:
        payload = source.readframes(source.getnframes())
        seconds = source.getnframes() / source.getframerate()
    frames.append(payload)
    frames.append(b"\x00\x00" * int(gap * rate))

    # `say` reports no word timings, so each word takes an equal share of the
    # turn. The scorer reads word times for attribution and DER, both of which
    # this tier checks for wiring rather than for tenths of a point.
    spoken = text.split()
    step = seconds / len(spoken)
    for offset, word in enumerate(spoken):
        words.append({
            "start": round(position + offset * step, 2),
            "end": round(position + (offset + 1) * step, 2),
            "text": word.strip(".,"),
            "speaker": speaker,
            "agent": speaker[-1],
            "truncated": False,
        })
    turns.append({
        "speaker": speaker,
        "start": round(position, 2),
        "end": round(position + seconds, 2),
    })
    position += seconds + gap

audio = os.path.join(out_dir, "smoke.wav")
with wave.open(audio, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(b"".join(frames))

truth = {
    "meeting": "smoke",
    "source": "smoke.wav",
    "windowSeconds": round(position, 2),
    "speakers": sorted(set(t["speaker"] for t in turns)),
    "agentToSpeaker": {t["speaker"][-1]: t["speaker"] for t in turns},
    "words": words,
    "turns": turns,
}
with open(os.path.join(out_dir, "smoke.json"), "w") as handle:
    json.dump(truth, handle, separators=(",", ":"), sort_keys=True)

print("smoke fixture: %.1fs, %d turns, %d words" % (position, len(turns), len(words)))
PY

echo "fixture ready in $OUT_DIR"
echo "run it with: scripts/eval.sh bench --truth $OUT_DIR/smoke.json --engine parakeet"
