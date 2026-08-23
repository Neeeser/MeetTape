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

## The suites

| Suite | Cases | What it is for |
|---|---|---|
| `ami-core` | all 14 | The deciding run. Every baseline comes from it |
| `ami-excerpts` | the 12 windowed cases | Accuracy without the 40 minutes the two whole meetings cost |
| `ami-long` | ES2008b, IS1009c | Whole meetings, which is what puts the chunk seams under measurement |
| `ami-single` | ES2002b | One real case, for checking a harness change end to end. It downloads a 73 MB recording |

`ami-single` was called `ami-smoke` and was renamed because it shares no
property with a smoke test: it needs the network, the annotations and about
four minutes of Neural Engine time.

The smoke tier is `scripts/make-bench-smoke.sh`, which synthesises a two-voice
fixture with `say`. It costs nothing, needs no network and runs anywhere, and
it catches wiring and assembly defects rather than accuracy: the reference
words are exactly what was spoken, and word timings are spread evenly across
each turn because `say` reports none.

```bash
scripts/make-bench-smoke.sh /tmp/meettape-bench-smoke
scripts/eval.sh bench --truth /tmp/meettape-bench-smoke/smoke.json --engine parakeet
```

Its turns strictly alternate and never overlap, so it cannot exercise the two
paths that overlap creates: chunk-seam de-duplication and the ordering floor
below. Both are zero on it by construction. A change to either has to be
measured on `ami-single` or `ami-core`.

## Running it

```bash
scripts/eval.sh bench --suite ami-core --engine parakeet --diarizer local \
    --out /tmp/parakeet.json --repeats 3 --keep-scratch
```

- `--repeats N` runs each case N times, prints the mean and the min-to-max
  spread per case, writes every run to `--out` with its run number, and
  compares the mean against the baseline. The default is 1.
- `--keep-scratch` writes each run's meeting folder beside `--out`, or into
  `bench-scratch/` when there is no `--out`, named `<case>-<engine>-<diarizer>`
  and `-runN` under repeats,
  instead of deleting it. A case that throws is the one worth reading, and it
  keeps its transcript, manifest and raw backend output.

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
scored whole rather than as an excerpt. The generator prints each case's speech
coverage and words per minute, which is where a sparse window shows up; it
writes neither into the JSON, because the harness derives both from the turns
it already reads.

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

Under `--repeats N` the comparison reads the mean of the runs, and the repeated
8-gram budget reads the worst of them. One sample is not enough for a local
backend: an alignment refusal happens or does not, and one case was observed
moving 6.6 points of WER between two runs of identical code, against a
tolerance of 1.5.

## How to read a number

Five things the table reports mean less than they look like they mean, and the
harness prints each next to the qualifier it needs.

- **Ordering floor.** The reference is grouped by turn and a transcript is a
  stream of utterances, so overlapping speech interleaves in one and not the
  other. An oracle transcript, holding every reference word in chronological
  order and nothing else, still scores 6.2% to 33.1% WER per case, mean 15.5%.
  That floor is `orderingFloorWer`, `wer` minus it is the `net` column, and on
  an overlap-heavy case the difference between two engines is mostly floor.
  `wer` itself is unchanged and is still what the baselines record.
- **Attribution coverage.** Attribution does not ask about a word spoken across
  another speaker's turn, because one stream of utterances cannot be right
  about both. That is 22.7% of the suite's words, 50.1% of EN2002a's and 49.8%
  of TS3009c's. `attributionCoverage` is the share that was asked about, so an
  attribution figure is never read as a score over the whole meeting.
- **Two speaker numbers, two mappings.** Attribution is strict: each reference
  speaker is claimed by at most one cluster, so a diarizer that splits a voice
  six ways is wrong about five of them. DER is merged: every leftover cluster
  is folded onto the voice it mostly covers. Merged is right for DER precisely
  because attribution is strict, otherwise one over-split is charged twice in
  two headline numbers. `derStrict` reports the injective basis as well, so
  nobody has to work out which mapping produced which figure.
- **DER above 100% is arithmetic.** The denominator is reference speech time
  and false alarm counts hypothesis speech outside it, which has no upper
  bound. This is the standard NIST definition and a hallucinating system will
  exceed 100%.
- **Sparse cases.** ES2003a holds 31.3% speech at 64 words per minute against
  78% to 99% and 146 to 217 for every case but ES2002a (59.5%, 103). It is kept
  deliberately, as the sparse-audio stress case: long silences are where a
  chunker mis-seams and a diarizer invents speakers. Its WER is decided on a
  third as many words as its neighbours', so one error moves it three times as
  far, and it is a poor case to rank two engines on. `speechCoverage` and
  `wordsPerMinute` are reported per case, computed from the truth's own turns.
  The window picker has no density floor, so a regenerated truth can produce
  another one.

## Filler and backchannels

Three word error rates are reported and they differ only in what is dropped
from both sides before the edit distance runs.

- `wer` drops nothing.
- `werNoFiller` drops hesitation noise (`uh`, `um`, `mm`, `hmm`, `uh-huh` and
  the rest of the set) and reference words the annotators marked truncated.
  6.7% of the reference tokens. This is the number the baselines read.
- `werConversational` drops backchannels as well: `yeah` (558 times), `okay`
  (282), `right`, `yep` and their spelling variants, another 3.6%. A
  clean-style engine writes none of them and is charged a deletion for each,
  which is house style rather than error. They are held apart from filler
  because they are ordinary English words in every other position: charging a
  system for writing "right" is as wrong as charging it for omitting it.

A full Whisper English normalizer (number words to digits, contraction
expansion, the British and American spelling table, its own filler list) was
evaluated against these three. It moved a case by at most 1.5 points and moved
Parakeet further than Cohere, which is to say it would have changed the ranking
by less than the run-to-run spread while adding a normalization table to
maintain and a second definition of what a word is. Rejected on that measurement.
Token-level fairness is worth having; a vocabulary dependency is not.

## Attribution

The ground truth is derived from the AMI Meeting Corpus manual annotations
(`ami_public_manual_1.6.2`), published by the University of Edinburgh under the
Creative Commons Attribution 4.0 International licence (CC BY 4.0,
https://creativecommons.org/licenses/by/4.0/). The word texts, timings and
speaker identifiers in `ground-truth/` are taken from that corpus. See
https://groups.inf.ed.ac.uk/ami/corpus/ for the corpus and its citation.
