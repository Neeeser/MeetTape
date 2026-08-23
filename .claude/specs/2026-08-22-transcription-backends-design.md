# Transcription backend overhaul

Approved 2026-08-22. Source of truth for the implementation on branch
`claude/openai-stt-models-aa669f`.

## Goal

Upgrade both transcription paths to the current best models, decouple the
pipeline from transcription timestamps so text-only models fit, keep
diarization and voice profiles local, merge the Processing and Local models
settings pages, and fix the consecutive same-speaker fragmentation in the
review panel.

## Verified facts the design rests on

- `gpt-transcribe` (July 2026, $0.0045/min) is OpenAI's recommended file STT
  model; supports `prompt`, `keywords`, `languages`; returns json/text only,
  no timestamps.
- `timestamp_granularities[]` (word or segment) is whisper-1 only.
- `gpt-4o-transcribe-diarize` ($0.006/min) is the only OpenAI model returning
  timestamps (segment) plus speakers, via `response_format=diarized_json`;
  no prompts; up to 4 known speakers (2-10 s reference clips);
  `chunking_strategy` required past 30 s.
- FluidAudio 0.15.6 (our exact pin, latest release) contains: the pyannote
  Community-1 diarization pipeline; Cohere Transcribe (beta,
  `CoherePipeline`, 35 s windows, `transcribeLong`, no timestamps, ~2.1 GB,
  ~8x realtime warm on M2, 3-6 min first ANE compile); Parakeet TDT v3
  (~460 MB, ~110x realtime, native word timings via `tokenTimings`); CTC
  models (`CtcModels`, 110M/0.6B) exposing frame log-probs with
  `frameDuration`, plus `CtcTokenizer`; FSMN VAD.
- Open ASR leaderboard (2026-08-21, AMI-cleaned WER): Cohere 7.01,
  Parakeet v3 9.41, whisper large-v3-turbo 13.87. Licenses all
  distribution-safe (Apache-2.0 / CC-BY-4.0 / MIT).
- MLX-based aligners cannot be built with Command Line Tools only; CTC
  forced alignment in CoreML/Swift can.
- Whisper turbo's random-character output is its documented
  hallucination-on-noise failure mode.

## 1. Timing as a declared capability, one alignment stage

- `TranscriptionBackend.timing: TranscriptTiming` with cases `.words`,
  `.segments`, `.text` (implemented as `.text` rather than the draft's
  `.none`, which clashes with Optional patterns), replacing
  `producesWordTimestamps: Bool`.
- New `TimingAligner` stage (MeetTapeLocalAI): CTC forced alignment using
  FluidAudio `CtcModels` (Parakeet CTC 0.6B; the 110M variant warped on weak posteriors when measured) + `CtcTokenizer` + a
  new Viterbi trellis in Swift. Input: track audio + transcript text.
  Output: word timings.
- Raw backend responses stay immutable as written. Aligned words are a
  derived artifact stored beside the raw output, regenerable, carrying the
  aligner identifier as provenance.
- Attribution, interleaving, dedup, and correction anchoring consume
  words+timings as today, unaware of their origin. Voice profiles,
  retraction, and speaker spans remain diarization-based and untouched.
- The aligner is English-focused; non-English audio uses Parakeet TDT v3
  native timings or segment attribution instead. Alignment runs under the
  LocalModelManager serialization (one heavy job at a time).

## 2. Model menus

Cloud transcription (default first):
1. `gpt-transcribe` - timing .none (locally aligned), keyword/context
   hints, $0.0045/min. Requires the ctc-aligner install unit (~600 MB).
2. `gpt-4o-transcribe-diarize` - timing .segments+speakers,
   self-contained, no local download.
3. `whisper-1` - timing .words (request `timestamp_granularities[]=word`
   from now on), legacy/compatibility.

Local transcription (default first):
1. Cohere Transcribe - timing .none (aligned), max local accuracy, 2.1 GB.
2. Parakeet TDT v3 - timing .words native, fast tier, ~460 MB.
3. Whisper large-v3-turbo - timing .words native, existing installs.

Diarization: unchanged. Local FluidAudio (Community-1) default; OpenAI
diarize optional. A "Custom..." free-text option preserves arbitrary
OpenAI model IDs.

Settings migrate to version 3: stored `models.transcription == "whisper-1"`
(the old default) upgrades to `gpt-transcribe`; custom values are left
alone. Existing meetings are protected per-meeting by the
one-track-one-backend rule.

## 3. OpenAI client changes

- `TranscriptionRequest` gains `keywords: [String]?` and
  `languages: [String]?`; multipart encoding for both.
- Per-model response handling: `gpt-transcribe` uses
  `response_format=json`; a response with text but no segments is valid
  for `.none`-timing models (the current malformedResponse rule becomes
  per-model).
- whisper-1 requests add `timestamp_granularities[]=word` (keep segment
  too) and the backend reports timing `.words`.
- One optional settings string, vocabulary hints, feeds `keywords` for
  gpt-transcribe. Empty by default; nothing automatic leaves the machine.

## 4. Per-model local install units

`LocalModelManager` moves from one 650 MB blob to install units: `whisper`,
`parakeet`, `cohere`, `ctcAligner`, `diarizer`. Each has its own receipt,
size, state (`notInstalled/downloading/installed/outdated/failed`), and
delete. The diarizer unit stays required for local diarization and voice
memory. Selecting an uninstalled model anywhere starts its download
immediately, shown inline on the row; selecting gpt-transcribe pulls
`ctcAligner` the same way. Cohere gets an explicit "preparing model" state
covering the first-load ANE compile.

Flag to verify during implementation: the FluidInference Cohere CoreML
repo is believed to download anonymously; if gated, auto-download needs an
interactive fallback.

## 5. Settings UI and wizard

- Processing and Local models tabs merge into one Processing tab:
  per-stage "Runs on: Cloud / Local" (display label Cloud; stored value
  stays `openai`), a model picker per side with size/speed/accuracy blurbs
  and inline install state, then the existing speaker-memory toggles and
  storage location line.
- Cloud tab keeps API key, enrichment toggles, metadata model. Its
  free-text transcription/diarization fields are replaced by the picker's
  "Custom..." option.
- The wizard's speech-models section offers the same tier choice,
  defaulting to max, with the same inline download.

## 6. Review panel grouping fix (independent)

Consecutive utterances with the same resolved speaker render as one block
with a single name header in the review panel; rows stay individually
correctable. Stored utterance granularity, correction anchors, and
assembler constants (1.2 s gap, 30 s cap) are unchanged in this pass.
Markdown rendering already collapses repeats.

## 7. Verification gates

- Viterbi aligner: unit tests on synthetic fixtures (monotonic timings,
  full word coverage) plus a `meettape-eval align` subcommand for real
  audio.
- New pinned tuning (Cohere window/overlap, aligner variant, Parakeet
  variant) asserted by `LocalConfigurationTests`.
- Backend mapping tests for the new choices; settings v3 migration tests.
- Default flips (Cohere local, gpt-transcribe cloud) validated against the
  live fixture with `meettape-eval asr` comparisons.
- gpt-transcribe live coverage behind `MEETTAPE_LIVE_OPENAI`.

## Build order

1. Review panel grouping fix (ships alone).
2. Cloud menu + client changes + whisper-1 word granularity.
3. Aligner + Cohere/Parakeet backends + per-model install units.
4. Settings UI merge + wizard.

One branch, staged commits, full verify gate per stage.
