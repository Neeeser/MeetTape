#!/usr/bin/env python3
"""Cross-check the Swift scorer's cpWER and tcpWER against MeetEval.

MeetEval is the reference implementation the CHiME challenges score with, so a
number our scorer produces should track what it computes on the same data.
This is developer tooling for validating a scorer change, not part of any test
run: it needs the `meeteval` package (`python3 -m pip install --user meeteval`)
and a bench run kept with `--keep-scratch`.

    scripts/eval.sh bench --truth T.json --engine parakeet \
        --out /tmp/o.json --keep-scratch
    python3 scripts/check-scorer-against-meeteval.py \
        --truth T.json --scratch /tmp/<case>-parakeet-local --out /tmp/o.json

Both sides are normalised the way the Swift scorer normalises (lowercase,
punctuation dropped, hyphens split) before MeetEval sees them, so the
comparison measures the metric, not the tokenizer. Small differences are
expected on tcpWER: our scorer spreads an utterance's words evenly across its
span and MeetEval pseudo-times them its own way, and the two land within a
point of each other when both are right.
"""

import argparse
import glob
import json
import os
import re
import sys

COLLAR = 5


def normalise(text: str) -> str:
    text = text.lower().replace("’", "'").replace("-", " ")
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", text).split())


def reference_segments(truth: dict) -> list[dict]:
    """One segment per reference turn, holding that turn's words."""
    by_speaker: dict[str, list[dict]] = {}
    for word in truth["words"]:
        by_speaker.setdefault(word["speaker"], []).append(word)
    for words in by_speaker.values():
        words.sort(key=lambda w: (w["start"], w["end"], w["text"]))
    segments = []
    for turn in sorted(truth["turns"], key=lambda t: (t["start"], t["end"], t["speaker"])):
        inside = [
            w for w in by_speaker.get(turn["speaker"], [])
            if w["start"] >= turn["start"] - 0.001 and w["end"] <= turn["end"] + 0.001
        ]
        text = normalise(" ".join(w["text"] for w in inside))
        if not text:
            continue
        segments.append({
            "session_id": truth["meeting"],
            "speaker": turn["speaker"],
            "start_time": turn["start"],
            "end_time": turn["end"],
            "words": text,
        })
    return segments


def hypothesis_segments(meeting: str, scratch: str) -> list[dict]:
    paths = glob.glob(os.path.join(scratch, "**", "raw", "transcript.json"), recursive=True)
    if not paths:
        raise SystemExit(f"no raw/transcript.json under {scratch}")
    with open(paths[0]) as handle:
        transcript = json.load(handle)
    segments = []
    for utterance in transcript["utterances"]:
        text = normalise(utterance["text"])
        if not text:
            continue
        segments.append({
            "session_id": meeting,
            "speaker": utterance.get("speakerKey", "") or "unlabelled",
            "start_time": utterance["start"],
            "end_time": utterance["end"],
            "words": text,
        })
    return segments


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--truth", required=True)
    parser.add_argument("--scratch", required=True, help="a --keep-scratch case folder")
    parser.add_argument("--out", help="the bench --out file, to print the Swift numbers beside")
    args = parser.parse_args()

    try:
        import meeteval.io
        import meeteval.wer
    except ImportError:
        print("meeteval is not installed: python3 -m pip install --user meeteval", file=sys.stderr)
        return 2

    with open(args.truth) as handle:
        truth = json.load(handle)
    reference = meeteval.io.SegLST(reference_segments(truth))
    hypothesis = meeteval.io.SegLST(hypothesis_segments(truth["meeting"], args.scratch))

    def rate(result) -> float:
        # The API returns one ErrorRate per session; there is one session.
        values = list(result.values()) if isinstance(result, dict) else [result]
        errors = sum(v.errors for v in values)
        length = sum(v.length for v in values)
        return errors / max(1, length)

    cp = meeteval.wer.cpwer(reference, hypothesis)
    # The defaults pseudo-time words inside their segment on both sides, which
    # is what the Swift scorer's even spread approximates.
    tcp = meeteval.wer.tcpwer(reference, hypothesis, collar=COLLAR)
    print(f"meeteval  cpWER {rate(cp):.4f}   tcpWER {rate(tcp):.4f} (collar {COLLAR}s)")

    if args.out:
        with open(args.out) as handle:
            rows = json.load(handle)
        for row in rows:
            score = row["score"]
            if score["meeting"] != truth["meeting"]:
                continue
            print(
                f"swift     cpWER {score.get('cpWer', float('nan')):.4f}"
                f"   tcpWER {score.get('tcpWer', float('nan')):.4f}"
                f"   (run {row.get('run', 1)}, {row['engine']}/{row['diarizer']})"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
