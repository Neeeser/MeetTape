# Benchmarks

The reference data `meettape-eval bench` scores against.

## What is here

- `ground-truth/*.json` holds one reference per case: the speakers, their turns
  and every word with a start and an end. A case names a window on a published
  AMI recording (`windowStart`, `windowSeconds`); two cases have no window and
  score a whole meeting, which is what puts the chunk seams under measurement.
- `manifest.json` pins the SHA-256 of every recording, the annotation archive
  the truth comes from, and the suite rosters.
- `baselines.json` holds the numbers a later run is compared against, one
  entry per `<engine>/<diarizer>/<meeting>`.

## No audio in the tree

CI fails the build on any committed audio file, and the recordings are 15 to
85 MB each. `scripts/fetch-bench-audio.sh` downloads them from the Edinburgh
mirror into `~/Library/Caches/meettape-bench` and verifies each one against the
pinned checksum, so a mirror serving a re-encoded copy is caught rather than
silently measured. The harness cuts the excerpt window itself, with
AVFoundation; there is no ffmpeg dependency anywhere in the path.

## Regenerating the truth

```bash
scripts/fetch-bench-audio.sh --annotations
python3 scripts/build-bench-truth.py \
    --annotations ~/Library/Caches/meettape-bench/ami_public_manual_1.6.2.zip \
    --window 360 ES2002a ES2002b ES2002c ES2002d ES2003a ES2005a \
                 IS1009a IS1008a TS3005a TS3009c EN2002a IB4005
python3 scripts/build-bench-truth.py \
    --annotations ~/Library/Caches/meettape-bench/ami_public_manual_1.6.2.zip \
    --whole ES2008b IS1009c
```

The generator reads the annotation archive alone: no audio, no ffmpeg. A
windowed case takes the six minutes holding the most speakers, and among those
the one where the quietest speaker talks most, because attribution and voice
enrolment both need every participant to say enough. Window selection is
deterministic, so regenerating from the same archive reproduces these files
byte for byte. ES2005a has only 306 seconds of annotated speech, so it is
scored whole rather than as an excerpt.

## Baselines

`baselines.json` comes from the deciding run of 2026-08-23: all 14 `ami-core`
cases on Parakeet with local diarization, which is the shipping configuration.
The same run measured Cohere over the same cases and it lost every one, so the
committed baselines are Parakeet's.

Regenerate from a bench run's own output:

```bash
scripts/eval.sh bench --suite ami-core --engine parakeet --diarizer local \
    --out /tmp/parakeet.json
python3 scripts/build-bench-baselines.py /tmp/parakeet.json \
    --out Benchmarks/baselines.json
```

The generator keeps the five numbers the rule reads (`wer`, `werNoFiller`,
`attribution`, `der`, `repeatedNgrams`), refuses a case that did not reach `complete`, and carries
the existing tolerances over.

## What a baseline check enforces

Pass `--baseline Benchmarks/baselines.json` and each case is compared against
its entry. A case with no entry is still run and still reported; it just has
nothing to compare against.

- `werNoFiller` may rise by 1.5 points, attribution may fall by 1.0, DER may
  rise by 2.0. The tolerances are absolute percentage points, sized to absorb
  the run-to-run variation a Neural Engine decode produces. Improvements are
  never failures.
- `wer` is recorded and not compared: filler words are transcribed or not on
  the decoder's whim and the assembly defect the suite hunts for shows in the
  stripped number.
- Repeated 8-grams ratchet: a case may not produce more than its entry records,
  and a case recorded at zero, or with no entry, may produce none at all. Two
  Parakeet cases carry a nonzero budget from the deciding run (ES2002c 1,
  IS1009c 7) pending the chunk-seam work that removes them.

Any regression exits nonzero, which is what makes the command usable as a gate.

## Attribution

The ground truth is derived from the AMI Meeting Corpus manual annotations
(`ami_public_manual_1.6.2`), published by the University of Edinburgh under the
Creative Commons Attribution 4.0 International licence (CC BY 4.0,
https://creativecommons.org/licenses/by/4.0/). The word texts, timings and
speaker identifiers in `ground-truth/` are taken from that corpus. See
https://groups.inf.ed.ac.uk/ami/corpus/ for the corpus and its citation.
