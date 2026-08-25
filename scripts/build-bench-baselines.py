#!/usr/bin/env python3
"""Write Benchmarks/baselines.json from a bench run's own output.

`meettape-eval bench --out FILE` writes one JSON object per case, holding the
configuration it ran under and the score it produced. This reads those objects
and keeps the six numbers the regression rule reads, keyed
"<engine>/<diarizer>/<meeting>".

    scripts/eval.sh bench --suite ami-core --engine parakeet --diarizer local \
        --out /tmp/parakeet.json
    python3 scripts/build-bench-baselines.py /tmp/parakeet.json \
        --out Benchmarks/baselines.json

Cases that did not reach `complete` are refused: a baseline recorded from a
partial run pins a number the pipeline never actually produced. Tolerances are
carried over from the existing file if there is one, so widening or narrowing
them survives a regeneration.

Several rows sharing a key, which is what `--repeats N` writes, are aggregated
the way the gate aggregates them: the mean over wer, werNoFiller, attribution
and der, and the worst over repeatedNgrams. That is `BenchAggregate.deciding`
in `Sources/MeetTapeBench`. Keeping the last row instead recorded run N while
the gate compared the mean of N.
"""

import argparse
import json
import os
import sys

DEFAULT_TOLERANCES = {"attribution": 1.0, "der": 2.0, "tcpWer": 2.0, "wer": 1.5}


def deciding(scores: list[dict]) -> dict:
    """The baseline entry for one key, over however many runs wrote it.

    Mirrors `BenchAggregate.deciding`: the compared numbers are the mean of the
    runs and the repeat budget is the worst of them, so a file written with
    `--repeats 3` records what the gate will compute from three runs.
    """
    ders = [score["der"] for score in scores if score.get("der") is not None]
    tcps = [score["tcpWer"] for score in scores if score.get("tcpWer") is not None]
    return {
        "attribution": mean(score["attribution"] for score in scores),
        "der": mean(ders) if ders else None,
        # The repeat budget a later run may not exceed.
        "repeatedNgrams": max(score.get("repeatedNgrams", 0) for score in scores),
        "tcpWer": mean(tcps) if tcps else None,
        "wer": mean(score["wer"] for score in scores),
        "werNoFiller": mean(score["werNoFiller"] for score in scores),
    }


def mean(values) -> float:
    values = list(values)
    return sum(values) / len(values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="+", help="bench --out files")
    parser.add_argument("--out", default="Benchmarks/baselines.json")
    args = parser.parse_args()

    runs: dict[str, list[dict]] = {}
    for path in args.results:
        with open(path) as handle:
            rows = json.load(handle)
        for row in rows:
            score = row["score"]
            meeting = score["meeting"]
            if row.get("state") != "complete":
                print(f"{meeting}: state {row.get('state')}, not a baseline", file=sys.stderr)
                return 1
            key = f"{row['engine']}/{row['diarizer']}/{meeting}"
            runs.setdefault(key, []).append(score)

    entries = {key: deciding(scores) for key, scores in runs.items()}

    tolerances = DEFAULT_TOLERANCES
    if os.path.exists(args.out):
        with open(args.out) as handle:
            tolerances = json.load(handle).get("tolerances", DEFAULT_TOLERANCES)

    document = {"entries": dict(sorted(entries.items())), "tolerances": tolerances}
    with open(args.out, "w") as handle:
        handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(entries)} baselines to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
