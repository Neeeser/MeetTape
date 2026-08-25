# Pipit benchmarks

`pipit-eval bench` runs a complete Pipit processing pipeline and compares its
meeting output with published reference transcripts. The benchmark covers
transcription, speaker separation, attribution, chunking, and transcript
assembly together.

## Repository data

| Path | Contents |
| --- | --- |
| `ground-truth/*.json` | Reference speakers, turns, words, and word timings |
| `manifest.json` | Corpus files, checksums, partitions, windows, and suite rosters |
| `baselines.json` | Recorded results keyed by engine, diarizer, and case |

Audio is downloaded into `~/Library/Caches/pipit-bench`. The repository contains
no recordings. CI rejects committed audio files.

## Suites

| Suite | Cases | Purpose |
| --- | ---: | --- |
| `ami-core` | 14 | Regression coverage across AMI excerpts and full meetings |
| `ami-excerpts` | 12 | Faster AMI accuracy checks without full-meeting chunking |
| `ami-long` | 2 | Full meetings and chunk seams |
| `ami-single` | 1 | One real case for benchmark runner checks |
| `ami-overlap` | 6 | AMI meetings with 38% to 46% overlapped speech |
| `icsi` | 4 | Six to nine speakers with 28% to 39% overlap |
| `notsofar` | 5 | Recent office meetings with 4% to 46% overlap |
| `deciding` | 14 | Held-out cases used to compare engines |

Use `deciding` when ranking one engine against another. Some `ami-core` and
`ami-overlap` cases appear in published training data for local models. Those
suites can detect a regression in one fixed configuration, but they cannot
support a fair model ranking. `manifest.json` records each case as `ami-train`,
`ami-dev`, `ami-eval`, `excluded`, or `clean`. Tests restrict `deciding` to
`ami-eval` and `clean` cases.

## Smoke check

The smoke fixture uses local `say` voices. It checks command wiring and
transcript assembly without a corpus download:

```sh
scripts/make-bench-smoke.sh /tmp/pipit-bench-smoke
scripts/eval.sh bench \
  --truth /tmp/pipit-bench-smoke/smoke.json \
  --engine parakeet
```

The fixture has alternating speakers and no overlap. Use a real suite to test
overlap handling, chunk seams, or accuracy.

## Run a suite

Download the required audio, then run the benchmark:

```sh
scripts/fetch-bench-audio.sh deciding

scripts/eval.sh bench \
  --suite deciding \
  --engine parakeet \
  --diarizer local \
  --out /tmp/parakeet.json \
  --repeats 3 \
  --keep-scratch
```

Useful options include:

- `--repeats N` runs each configuration several times and compares the mean.
- `--resume` continues an output file and skips completed runs.
- `--keep-scratch` preserves meeting folders, raw model output, and transcripts.
- `--baseline Benchmarks/baselines.json` enables the regression gate.
- `--allow-missing-baseline` permits exploratory cases without recorded results.

The output file is updated after each case. A stopped campaign can resume
without repeating completed model calls.

## Metrics

| Metric | Meaning |
| --- | --- |
| `wer` | Word error rate over the serialized transcript |
| `werNoFiller` | WER after removing hesitation sounds and truncated reference words |
| `werConversational` | WER after also removing conversational backchannels |
| `cpWer` | Per-speaker WER after the best one-to-one speaker assignment |
| `tcpWer` | Per-speaker WER with a five-second word timing constraint |
| `attribution` | Word ownership under a strict one-to-one speaker mapping |
| `der` | Diarization error after split clusters are merged by reference speaker |
| `derStrict` | Diarization error under the strict speaker mapping |
| `repeatedNgrams` | Repeated 8-word passages that indicate loops or bad chunk seams |
| `rtfx` | Processing speed relative to recording duration |

Use `tcpWer` as the main result for overlap-heavy suites. It charges missed
overlapped words, words assigned to the wrong speaker, and timing errors in one
measure.

Serialized WER has an ordering floor because simultaneous speakers must be
written in one sequence. The report includes `orderingFloorWer`, speech
coverage, attribution coverage, overlap ratio, and words per minute so each
result carries its main qualifiers.

DER can exceed 100%. False alarm duration has no upper bound relative to the
reference speech duration.

## Baseline gate

Create or update baselines from a complete output file:

```sh
python3 scripts/build-bench-baselines.py /tmp/parakeet.json \
  --out Benchmarks/baselines.json
```

A gated case needs a matching baseline entry. Default tolerances use absolute
percentage points:

| Metric | Allowed regression |
| --- | ---: |
| `werNoFiller` | 1.5 points higher |
| `attribution` | 1.0 point lower |
| `der` | 2.0 points higher |
| `tcpWer` | 2.0 points higher |

Repeated 8-grams use a fixed budget from the baseline. A case may not produce
more repeated passages than its recorded result. Improvements do not fail the
gate.

For repeated runs, numeric comparisons use the mean. The repeated 8-gram check
uses the worst run.

## Data provenance

`scripts/fetch-bench-audio.sh` downloads recordings and annotation archives at
pinned revisions and verifies their SHA-256 checksums. The benchmark cuts
excerpt windows with AVFoundation.

Ground truth comes from these sources:

- [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/), manual
  annotations version 1.6.2
- [ICSI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/icsi/), core NXT
  annotations version 1.0
- [NOTSOFAR-1](https://huggingface.co/datasets/microsoft/NOTSOFAR), evaluation
  release `240825.1_eval_full_with_GT`

The derived word text, timings, and speaker identifiers are distributed under
the source corpora's Creative Commons Attribution 4.0 licenses. The recordings
remain in the local cache and are not redistributed.

Regenerate the committed truth with `scripts/build-bench-truth.py`. The script
reads pinned annotation data and selects windows deterministically. Review the
resulting diff and run the benchmark tests before replacing ground truth.

## Scorer validation

The Swift cpWER and tcpWER implementations are checked against MeetEval with:

```sh
scripts/check-scorer-against-meeteval.py \
  --truth Benchmarks/ground-truth/ES2002b.json \
  --scratch /tmp/ES2002b-parakeet-local \
  --out /tmp/parakeet.json
```

Scorer tests also cover exact transcripts, known deletion rates, shuffled
speaker labels, split clusters, filler handling, timing collars, and baseline
failures.
