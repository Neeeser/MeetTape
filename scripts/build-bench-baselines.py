#!/usr/bin/env python3
"""Write Benchmarks/baselines.json from a bench run's own output.

`meettape-eval bench --out FILE` writes one JSON object per case, holding the
configuration it ran under and the score it produced. This reads those objects
and keeps the four numbers the regression rule reads, keyed
"<engine>/<diarizer>/<meeting>".

    scripts/eval.sh bench --suite ami-core --engine parakeet --diarizer local \
        --out /tmp/parakeet.json
    python3 scripts/build-bench-baselines.py /tmp/parakeet.json \
        --out Benchmarks/baselines.json

Cases that did not reach `complete` are refused: a baseline recorded from a
partial run pins a number the pipeline never actually produced. Tolerances are
carried over from the existing file if there is one, so widening or narrowing
them survives a regeneration.
"""

import argparse
import json
import os
import sys

DEFAULT_TOLERANCES = {"attribution": 1.0, "der": 2.0, "wer": 1.5}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="+", help="bench --out files")
    parser.add_argument("--out", default="Benchmarks/baselines.json")
    args = parser.parse_args()

    entries = {}
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
            entries[key] = {
                "attribution": score["attribution"],
                "der": score.get("der"),
                "wer": score["wer"],
                "werNoFiller": score["werNoFiller"],
            }

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
