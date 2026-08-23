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

| Suite | Cases | Corpus | Overlap | What it is for |
|---|---|---|---|---|
| `ami-core` | all 14 | AMI | 3 to 31% | The deciding run. Every baseline comes from it |
| `ami-excerpts` | the 12 windowed cases | AMI | 3 to 31% | Accuracy without the 40 minutes the two whole meetings cost |
| `ami-long` | ES2008b, IS1009c | AMI | 5 to 6% | Whole meetings, which is what puts the chunk seams under measurement |
| `ami-single` | ES2002b | AMI | 12% | One real case, for checking a harness change end to end. It downloads a 73 MB recording |
| `ami-overlap` | 6 | AMI | 38 to 46% | Four people talking over each other, on meetings `ami-core` does not touch |
| `icsi` | 4 | ICSI | 28 to 39% | The same, with six to nine people in the room, which is what stresses speaker counting |

`ami-excerpts`, `ami-long` and `ami-single` are subsets of `ami-core`.
`ami-overlap` and `icsi` share no meeting with it.

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
  `scripts/build-bench-baselines.py` folds those runs the same way, so a
  baseline built from an `--out` file written under repeats records the mean of
  the runs and the worst of their repeated 8-gram counts, which is what the
  gate will compare against.
- `--keep-scratch` writes each run's meeting folder beside `--out`, or into
  `bench-scratch/` when there is no `--out`, named `<case>-<engine>-<diarizer>`
  and `-runN` under repeats,
  instead of deleting it. A case that throws is the one worth reading, and it
  keeps its transcript, manifest and raw backend output.

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
| Btr001 | 3480 to 3840 s | 38.6% | 6 | 1830 |
| Bmr019 | 3225 to 3585 s | 37.9% | 9 | 1989 |
| Bsr001 | 105 to 465 s | 36.6% | 8 | 2047 |
| Bed016 | 15 to 375 s | 28.5% | 7 | 1414 |

The `ami-core` windows overlap 3 to 31%, median 12%, so the two new suites move
the measurement into speech the old roster barely held.

## A duplicated passage in Bsr001

ICSI's own annotation of Bsr001 channel A repeats a stretch of transcript
verbatim: four adjacent blocks of 24, 21, 6 and 5 words between 293 and 362 s,
56 words in all, written twice where the audio holds them once. The second copy
carries almost no alignment, which is how it survived into the published file.
Every one of those words is inside the scored window, so a transcriber that
gets the audio exactly right still scores 56 deletions against 2047 reference
words: about 2.7 points of WER that no decoder can remove, 1.2 of them from the
24-word block alone. Remember it when `icsi` gains baseline entries. Bsr001's
WER will sit that much above the other three cases, and the gap is the
annotation rather than the engine.

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
rather than as an excerpt. Each case prints its speech coverage, its words per
minute and how many of its words carry no duration, none of which the JSON
holds: the harness derives coverage and rate from the turns it already reads,
and a nonzero duration count is a defect in the run that produced it.

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
carries a word class in `c`, splits clitics into their own elements, and has no
`meetings.xml`, so the speaker a channel belongs to comes from the
`participant` attribute on its segments. Around half the words on some ICSI
channels carry no alignment, and filling them from their neighbours collapsed
them onto a point: 218 words inside 25 seconds on one channel of Bro024, half
the reference's speech time missing, and a false-alarm term measuring the
annotation rather than the diarizer. The segments carry the times, so an
unaligned run is spread across the room inside its segment, and a run whose
segment leaves it no room takes 40 ms a word rather than a single instant,
stopping at the next segment on that channel. The reader
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
  Net is a lower bound on the share of `wer` that is not ordering, not a split
  of one from the other: the two coincide on the same words, and ES2002b scores
  18.5% against an 18.1% floor while holding at least 10.1 points of deletions
  of its own. `wer` itself is unchanged and is still what the baselines record.
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

The `ami-core`, `ami-excerpts`, `ami-long`, `ami-single` and `ami-overlap`
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
