# Benchmarks

The reference data `meettape-eval bench` scores against.

## What is here

- `ground-truth/*.json` holds one reference per case: the speakers, their turns
  and every word with a start and an end. A case names a window on a published
  AMI or ICSI recording (`windowStart`, `windowSeconds`); two cases have no
  window and score a whole meeting, which is what puts the chunk seams under
  measurement. `overlapRatio` is the share of the window's speech time carrying
  two or more voices at once.
- `manifest.json` pins the SHA-256 of every recording, the annotation archive
  each corpus's truth comes from, and the suite rosters.
- `baselines.json` holds the numbers a later run is compared against, one
  entry per `<engine>/<diarizer>/<meeting>`.

## The suites

| Suite | Cases | Corpus | Overlap | What it measures |
|---|---|---|---|---|
| `ami-core` | 14 | AMI | 3 to 31% | The shipping configuration's WER, attribution and DER, plus two whole meetings for the chunk seams |
| `ami-overlap` | 6 | AMI | 38 to 46% | Four people talking over each other, on meetings `ami-core` does not touch |
| `icsi` | 4 | ICSI | 42 to 53% | The same, with five to seven people in the room, which is what stresses speaker counting |

`ami-excerpts`, `ami-long` and `ami-smoke` are subsets of `ami-core`.

Every `ami-overlap` and `icsi` window, with the overlap ratio the truth
records:

| Case | Window | Overlap | Speakers | Words |
|---|---|---|---|---|
| EN2002d | 1185 to 1545 s | 46.4% | 4 | 1449 |
| EN2002b | 225 to 585 s | 44.5% | 4 | 1259 |
| IN1012 | 2220 to 2580 s | 40.1% | 4 | 1349 |
| IS1003d | 510 to 870 s | 39.1% | 4 | 1385 |
| IS1006d | 1440 to 1800 s | 38.7% | 4 | 951 |
| ES2015d | 840 to 1200 s | 38.0% | 4 | 1437 |
| Bro024 | 4215 to 4575 s | 53.1% | 6 | 1038 |
| Bmr014 | 2535 to 2895 s | 47.3% | 6 | 1200 |
| Bmr006 | 4350 to 4710 s | 44.6% | 5 | 1088 |
| Bmr013 | 2445 to 2805 s | 42.4% | 7 | 1228 |

The `ami-core` windows overlap 3 to 31%, median 12%, so the two new suites move
the measurement into speech the old roster barely held.

## Which channel ICSI is scored on

ICSI publishes the headset mix as `<meeting>.interaction.wav`, one signal named
`interaction` in the corpus metadata. It is the sum of the close-talking
microphones, which is what AMI's `Mix-Headset` is, so the two corpora are scored
on the same kind of input and a difference between them is a difference in the
meetings rather than in the microphones. The individual headset channels are
published as well, per speaker, and are not used: a per-speaker channel hands
the diarizer the answer.

## No audio in the tree

CI fails the build on any committed audio file, and the recordings are 15 to
190 MB each. `scripts/fetch-bench-audio.sh` downloads them from the Edinburgh
mirror into `~/Library/Caches/meettape-bench` and verifies each one against the
pinned checksum, so a mirror serving a re-encoded copy is caught rather than
silently measured. The harness cuts the excerpt window itself, with
AVFoundation; there is no ffmpeg dependency anywhere in the path.

```bash
scripts/fetch-bench-audio.sh ami-overlap
scripts/fetch-bench-audio.sh icsi
```

## Regenerating the truth

```bash
scripts/fetch-bench-audio.sh --annotations
scripts/fetch-bench-audio.sh --annotations icsi
AMI=~/Library/Caches/meettape-bench/ami_public_manual_1.6.2.zip
ICSI=~/Library/Caches/meettape-bench/ICSI_core_NXT.zip

python3 scripts/build-bench-truth.py --annotations "$AMI" \
    --window 360 ES2002a ES2002b ES2002c ES2002d ES2003a ES2005a \
                 IS1009a IS1008a TS3005a TS3009c EN2002a IB4005
python3 scripts/build-bench-truth.py --annotations "$AMI" \
    --whole ES2008b IS1009c
python3 scripts/build-bench-truth.py --annotations "$AMI" \
    --overlap-rank 6 --all --exclude-suite ami-core
python3 scripts/build-bench-truth.py --corpus icsi --annotations "$ICSI" \
    --overlap-rank 4 --all
```

The generator reads the annotation archive alone: no audio, no ffmpeg. Window
selection is deterministic, so regenerating from the same archive reproduces
these files byte for byte, from the published zip or from an unpacked copy of
it. ES2005a has only 306 seconds of annotated speech, so it is scored whole
rather than as an excerpt.

A default windowed case takes the six minutes holding the most speakers, and
among those the one where the quietest speaker talks most, because attribution
and voice enrolment both need every participant to say enough.

`--overlap-rank N` scores every meeting's six minutes instead and keeps the N
that overlap most. The ratio is overlapped speech over all speech, computed
from the word timings without bridging the gaps between words: bridging invents
simultaneity the recording does not hold. Two gates come before the ratio. A
window must hold four voices with at least five seconds each, because two
people talking over each other tests nothing about counting speakers and
somebody who says one word in six minutes is not a speaker any diarizer can be
asked to find. And speech must fill half the window: the ratio divides by
speech time, so silence is free, and ranking on the ratio alone put ICSI's
digit-reading sections on top, where the participants read numbers aloud over
each other and a quarter of the span is speech. Words below either gate stay in
the reference. They were spoken, and dropping them would score them as
insertions.

`ami-overlap` ranks the 157 AMI meetings that `ami-core` does not use and takes
the top six, which come from six meetings across five series. `icsi` ranks all
75 ICSI meetings and takes the top four.

Two corpora are read by two readers behind one interface. AMI marks
punctuation with a `punc` attribute and keeps contractions inside a word; ICSI
carries a word class in `c`, splits clitics into their own elements, leaves
some words unaligned, and has no `meetings.xml`, so the speaker a channel
belongs to comes from the `participant` attribute on its segments. The reader
docstrings in `scripts/build-bench-truth.py` record what each difference costs.

## Baselines

`baselines.json` comes from the deciding run of 2026-08-23: all 14 `ami-core`
cases on Parakeet with local diarization, which is the shipping configuration.
The same run measured Cohere over the same cases and it lost every one, so the
committed baselines are Parakeet's. `ami-overlap` and `icsi` have no entries
yet: a case with no baseline is still run and still reported, it just has
nothing to compare against, and these two are pending the full comparative run.

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

The `ami-core`, `ami-excerpts`, `ami-long`, `ami-smoke` and `ami-overlap`
ground truth is derived from the AMI Meeting Corpus manual annotations
(`ami_public_manual_1.6.2`), published by the University of Edinburgh under the
Creative Commons Attribution 4.0 International licence (CC BY 4.0,
https://creativecommons.org/licenses/by/4.0/). The word texts, timings and
speaker identifiers in `ground-truth/` are taken from that corpus. See
https://groups.inf.ed.ac.uk/ami/corpus/ for the corpus and its citation.

The `icsi` ground truth is derived from the ICSI Meeting Corpus core NXT
annotations (`ICSI_core_NXT.zip`, v1.0), distributed by the University of
Edinburgh under the same CC BY 4.0 licence. See
https://groups.inf.ed.ac.uk/ami/icsi/ for the corpus, its licence page and its
citation. The recordings themselves are published under CC BY 4.0 too and are
downloaded, never redistributed.

## What is not here: LibriCSS

LibriCSS is the standard overlapped-ASR set, LibriSpeech re-recorded at
controlled overlap ratios from 0 to 40%, and it is not in these suites. Its
only official distribution is a Google Drive folder that the corpus's own
`dataprep.sh` fetches with a cookie-and-confirm-token dance
(`docs.google.com/uc?export=download&confirm=...&id=1Piioxd5G_...`), which has
no stable URL to pin and no checksum to verify. The one third-party copy on
Hugging Face is a re-upload with no provenance, 55 downloads and a licence tag
that contradicts LibriSpeech's, so pinning it would pin a stranger's file. The
suites here take audio from a published corpus mirror or not at all.
