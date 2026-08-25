# Pipit development notes

Reference material for anyone working in this repository. Product behaviour is
documented in the README; this file covers how to build, test and change the
code.

## Build and test

```bash
./scripts/build.sh [debug|release]   # canonical build
./scripts/test.sh [--filter X]       # canonical test run
./scripts/bundle-app.sh [debug|release]   # assembles dist/Pipit.app
./scripts/check-offline.sh           # the suite must download no model
cd extension && npm test             # browser sensor logic
```

Always go through the scripts. They source `scripts/spm-env.sh`, which repairs
two Command Line Tools defects and exports the flags a bare `swift build` would
miss. Sourcing it from zsh fails: it reads `BASH_SOURCE`.

`check-offline.sh` runs the ordinary suite and fails if a model fetch started.
A test that builds a real `PipitRuntime`, `SetupModel` or `LocalModelManager`
can start an install from a detached Task: the runner neither waits for it nor
reports it, so the only trace is FluidAudio's own log line and the bytes it
leaves in the test's temporary directory. Run it after touching a test that
constructs any of those three.

Four properties of the development environment determine how the project is set
up:

- The development machine has Command Line Tools installed without Xcode, so
  there is no `xcodebuild` and no `.xcodeproj`. The application bundle is
  assembled by `scripts/bundle-app.sh`.
- XCTest and swift-testing ship with Xcode, so the test suite runs as an ordinary
  executable built on `Sources/TestKit`. `swift test` does not work here.
- SwiftUI's `@State` and `@Binding` are macros whose compiler plugin also ships
  with Xcode. View state therefore lives in `@Observable` model classes owned by
  `WindowManager`, and bindings are constructed with `Binding(get:set:)`. The
  Observation macro is available, so views still update automatically. Do not
  reintroduce `@State`.

- The same installs ship a stub `usr/include/c++/v1` holding around a dozen
  headers, which shadows the SDK's real 192-header libc++ and breaks every
  C-family target. FluidAudio has two, so `spm-env.sh` detects the stub and puts
  the SDK include path back in front through
  `-Xcxx -I$(xcrun --show-sdk-path)/usr/include/c++/v1`. The flags land in the
  `PIPIT_SWIFT_FLAGS` array, which every caller of `swift build` in
  `scripts/` forwards. A new build entry point must do the same.

`scripts/spm-env.sh` also repairs a stale `PackageDescription.private.swiftinterface`
found in some Command Line Tools installs, without which every manifest fails to
link. It copies both `ManifestAPI` and `PluginAPI`, because the dependency graph
builds plugins and the plugin manifests fail the same way, and it strips every
stale private swiftinterface rather than only `PackageDescription`'s, since
`PackagePlugin` ships one too. It does nothing on a healthy toolchain.

## Local processing

The speech stack is pinned, not resolved: `argmax-oss-swift` exactly 1.1.0 and
`FluidAudio` exactly 0.15.6, which are the revisions the accuracy, speed and
threshold numbers were measured on. Moving either one is a re-evaluation, not a
bump.

| Rule | Reason |
|---|---|
| `clustering.warmStartFa = 0.20` | The library ships 0.07, which found 8 speakers where there were 17 and left 35.4% of reference speakers without a cluster. 0.20 improves DER, JER, speaker count, word attribution and speaker recovery at once |
| Never set `clustering.numSpeakers` automatically | The tuned automatic configuration beat the exact true count on word attribution, on merges required and on speakers recovered. A participant list is worse than not asking |
| `skipSpecialTokens = true` | The default is false and leaks `<\|startoftranscript\|>` into the transcript text |
| `wordTimestamps = true`, no prompt conditioning | Prompting improves punctuation and collapses word timings: 198 distinct word starts became 153, 43 with zero duration. Attribution consumes the timings |
| No VAD chunking | 15% faster over 65 minutes, dropped 231 of 9278 words, and produced a segment whose start went backwards |
| Models under Application Support, never Documents | WhisperKit defaults to `~/Documents/huggingface`, putting 624 MB where Finder shows it and iCloud syncs it |
| Pass `modelFolder` explicitly on every load | WhisperKit with `download: false` does not resolve its own cache and fails with "Model folder is not set" |
| Timing is a declared backend capability, and a text-only chunk goes through the CTC aligner before assembly | The best transcription models (gpt-transcribe, Cohere) return no timings at all, and the assembler, attribution, dedup and correction anchors all consume timings. `whisper-1` is the only OpenAI model with word timestamps |
| An alignment refusal writes one whole-chunk segment, never a failed meeting | The words are already safe on disk; a Viterbi with no monotonic path must not take the transcript with it |
| An aligner that cannot be installed fails the stage; one that refuses does not | Only the transcribing stage aligns, and nothing revisits a finished meeting, so swallowing a failed download shipped five-minute utterances permanently. A download clears by retrying; a refusal does not |
| A text-only backend is chunked for the aligner, not for its own request limit | The trellis is frames times tokens: at the API's own 1400 s a chunk exceeded the cap, alignment refused, and nineteen minutes became one utterance on one speaker |
| Word texts carry a leading space | The assembler concatenates word texts verbatim, the Whisper convention. Aligned words without it rendered as "weshipfriday" |
| Models install as independent units, and picking a model is the consent for its download | One 650 MB blob meant choosing a 21 MB diarizer-only configuration still offered the full download, and a 2.1 GB engine must never arrive on an upgrade nobody asked for. No stored model identifier is ever migrated for the same reason |
| A fresh install transcribes locally with Apple's SpeechAnalyzer on macOS 26+, and with Parakeet before it | The 2026-08-24 deciding run, 14 held-out cases no local model trained on: Parakeet leads every accuracy median (tcpWER 68.6%, 7 repeated 8-grams) and Apple sits 1.3 points behind at the same speed with nothing to download, so the first meeting transcribes before any download finishes. Parakeet is one click away, labelled the accuracy pick |
| Only held-out or uncontaminated meetings may rank one engine against another | Parakeet's training data includes AMI and nine of the fourteen old core cases are AMI training meetings, so the original 14-of-14 margin over Cohere was part memorization. The `deciding` suite (AMI eval partition, ICSI, NOTSOFAR-1) is pinned to `ami-eval` and `clean` partitions by a test; the contaminated suites regression-test a fixed engine against itself, where contamination sits on both sides |
| Cohere and Whisper stay installed where chosen and leave the offered list; a picker always shows the stored choice | On the held-out suite Cohere lost all 14 cases with 178 repeated 8-grams and Whisper won 1, so neither earns a fresh download. No stored identifier migrates, and `pickerRows` appends an unoffered selection so the machine that chose it never sees an empty picker one click from a download |
| The offered cloud models are gpt-4o-transcribe-diarize, the default, and gpt-transcribe; whisper-1 is Custom-only | whisper-1 won zero of fourteen cases against the free local default and its word timings come from the local aligner now. gpt-transcribe returned empty output for chunks of the five hardest meetings across two attempts, a documented behaviour of the model family on long hard audio, so it stays offered for its strength on ordinary recordings with the empty-chunk guard failing the meeting loudly rather than filing a hole |
| The diarizer unit is required in every configuration, cloud included | Voice memory embeds a cloud diarizer's intervals with those models. Leaving it out of the required set made `ensureInstalled` report success on a machine with nothing installed, and the extractor threw from inside the speaker stage, which is not retryable |
| The 1.1 MB voice detector is required in every configuration for the same reason | Every backend fabricates filler for a microphone track that is mostly not speech, cloud ones included. Leaving it optional would ship the configuration most exposed to the defect, cloud transcription of a listener's own microphone, without the guard |
| A caller of `ensureInstalled` names the units it needs rather than taking the whole required set | Voice memory needs the diarizer. Judging it against everything meant that adding any unit to the required set turned voice memory off on every machine already installed, because the receipt for the new unit is missing and the caller reads that as "no models" |
| Voice memory never fails a meeting | It is a side effect of the meeting, not part of it, and the stage that would fail comes before the one that writes the markdown and the mixdown |
| Whoever already owns a track's words keeps them, whatever the settings say now | Deciding the diarizer's purpose from the current transcription setting alone made a cloud pass claim `.words` on a track a local engine had already chunked: same purpose, same chunk names, every plan skipped as done, nothing diarized |
| A chunk identifier is unique per producer, not per track | A chunked local transcriber and a cloud diarizer both name chunks after the track, so the diarizer's plans matched chunks the transcriber had written, every one was skipped as already done, and the far end came back as one unattributed speaker with the meeting reporting success |
| A local engine's chunks run one at a time | An actor yields at every await, so `runChunks` asking for three really does run three decodes against one Neural Engine |
| The seconds two chunks share are settled by matching their words, never by a cut in time | A midpoint cut assumes both chunks transcribed the overlap. Where the later one had not, ES2002b lost about 230 words per six minutes, and a chunk whose alignment refused carries one wordless segment starting at the chunk, so as the later side of a seam it lost all 118 of its words and as the earlier side it duplicated the chunk after it |
| Every chunk is deduplicated against every earlier chunk that still reaches it | A chunk whose content runs past the next boundary overlaps chunk N+2, which adjacent-pair trimming never sees: 153 repeated 8-grams on one ES2003a run |
| A chunk that loops one phrase is a failed chunk, and the last attempt drops it | Five of sixteen ES2003a chunks returned the same fabricated paragraph on sparse audio: 438 invented words against a 386-word reference and 193% DER, reported as success. How many loop varies by run. A deterministic decoder loops again, so failing forever would cost the meeting rather than the window |
| A whole track transcribed in one request is never dropped for looping | The one chunk is the meeting, so the drop that costs a window costs everything: an empty raw transcript, enrichment returning early, and a meeting completing with an empty transcript.md reported as success |
| A chunk under twenty distinct words is not measured for looping | Counting repeated phrase positions saturates on real speech that repeats: 48 words of backchannel and counting to ten four times both score 1.00 against a 0.20 limit, on 3 and 10 distinct words. The fabricated paragraph holds 36 distinct words of 76 and ordinary dialogue 71 of 87 |
| Score, margin and duration together for a name | Over 326 verified-distinct speakers the worst impostor scored 0.957 against the true speaker's own 0.951. Score alone names the wrong person |
| Score against a derived centroid only | A maximum over exemplars lifted impostor scores far more than genuine ones and cost a quarter of the margin |
| Only the mic track and a human confirmation may write a profile | A match that widens the profile it matched against turns one wrong answer into a permanent one |
| No vectors in a meeting folder | The folder is what a user copies, syncs and shares, and an embedding matches the same person across devices, rooms and years |
| One heavy job at a time, paused while recording | Transcription is 92% of the work and both models target the Neural Engine, so a second meeting takes time from the first rather than adding any |
| An optional cloud stage asks `isConfigured()` first | Both speech backends default to local and the enrichment switches default on, so without it every meeting on a fresh install failed before the step that writes the markdown and the mixdown |
| A key store answers `isKnownAbsent` for itself | Taking the protocol default meant "a read that failed" read as "no key", which is the same failure by another route |
| The API key is read from the keychain once per process and held in memory | An uncached read raises a login-keychain prompt on any build the item's access control does not trust, and there was one read per request: enrichment alone asks five times per meeting. Saving a key hands it to the cache and a 401 drops it, so rotation still takes effect without a relaunch |
| The microphone track enrols only when the far end has its own track, and only a voice unlike its clusters | Dominance is not identity: on a pairing where echo cancellation falls back, the presenter dominates the user's own track |
| Every stored vector records the audio it came from: a recording, a track and time spans | Provenance kept as a cluster label stops matching the moment a re-analysis renumbers the runs, and a line-level correction produces material belonging to no cluster at all |
| Retraction is a span lookup, never an inference from current cluster state | Overlapping audio cannot belong to two people. Answering from labels was wrong after every re-analysis, merge and line correction |
| A partially contradicted vector survives while 45 s of its audio is still its owner's | The bar that let it be stored. Dropping on any overlap destroyed twenty minutes of confirmed material over a three-second correction; keeping regardless let a vector be corrected away a little at a time |
| Contradicted spans stay on the row and stop counting | Deleting them would make the row claim the vector is purer than it is; leaving them counted would measure every correction against the original |
| Chunk purpose is decided by which backend owns the words, once per track | Deciding it from what is on disk flipped mid-meeting on a resume and the assembler dropped the far end permanently |
| Display and confirmation are separate predicates | A correction must survive its line being merged, and must not then enrol the rest of that line's voice |
| One track's words come from one backend | A cloud run that failed and was retried after switching to Local landed both sets on the same track, and the far end was assembled twice in two models' phrasing |
| A re-analysis supersedes a diarizer's own labels; the first pass does not | A backend that transcribes and diarizes in one request writes labels into the words, so Run under Re-analyze speakers wrote a run nothing read |
| A batch correction is resolved, applied in memory and written once | A failure at line 18 of 30 left seventeen renamed with no error shown, and nothing recording that a rebuild was owed |
| One candidate in the gallery is a suggestion, never an automatic name | There is no runner-up and so no separation to measure. The worst impostor over 326 speakers scored 0.957 against the true speaker's own 0.951, so no absolute score separates them |
| Two clusters may be one identity when they do not overlap in time, and never when they do | The tuned clusterer prefers splitting over merging, so one voice as two clusters is expected. One person cannot talk over themselves |
| A half-match against a candidate this meeting seeded is remembered as nothing | Two centroids a few hundredths apart split each other's margin, so that voice is never recognised again, in any meeting |
| Processing reaches a meeting folded into another | `combine` links metadata and moves no audio, so the folded folder is the only copy of the second half of a dropped call |
| Only the archive listing hides a folded continuation; every operation named by an identifier reaches it | A correction on a line from the second half resolved to nothing and threw, so the panel showed a change nothing had stored |
| A dropped and rejoined call is one logical meeting over two immutable recordings | Each keeps its own segments, manifest, raw output and speaker map. The combined duration and transcript are derived on read, so separating them again is clearing two fields |
| A boundary a person puts in the transcript lands on a word, never on a proportion of the text | A correction hands its span to voice memory. A line whose backend reported no word timings therefore divides only at its edges, and a turn keeps its timings only when every segment in it was timed: half a word list deleted the untimed half of the turn the first time anyone split that line |
| Dividing a corrected line clips the correction to each piece rather than re-anchoring it | A correction's width is what says how much of a line a person vouched for. Stretched to the piece, a name set on a three-second interjection would confirm the whole piece and put the other speaker's audio in that person's profile |
| A correction carries one window per line, in that line's own coordinates | The lines of a turn are not in time order: the line printed second can begin before the line printed first. One range over the pair put a boundary in the wrong line, and a selection dragged backwards across a seam ended before it began |
| A segment on the local user's track survives only if it holds words, a detector fires inside it, and the microphone is not quieter than the far end | Every backend invents filler for a microphone track that is mostly not speech. Over four meetings, 181 of the 222 segments on the user's track were words nobody said: 37 after one meeting's last real sentence at 4:11, a second meeting's whole track as 125 segments of " ♪", a third producing "Thank you." six times for a user who never spoke. Measured with the shipping model, the three clauses remove 178 of the 181 and cost 2 of the 41 genuine segments |
| The detector cannot judge leakage and the level comparison cannot judge silence, so both are required | The far end coming back through the speakers is speech, and Silero correctly scores it 0.99. On its own the detector removed 80 of the 181. Fabrication over true silence reads 0.000 and no level comparison catches it |
| A segment with no letter or digit in it is not words | `DegenerateTranscriptPolicy` strips everything non-alphanumeric before counting repetition and is then left with nothing to count, so one meeting's 125 identical " ♪" segments scored zero and passed |
| Speech evidence is measured in one stage and only for a track the gate judges, then read on every assembly | Re-measuring decodes both tracks again on every re-analysis, and on a machine whose detector has since been deleted it would put the fabricated lines back. An imported recording's microphone holds everybody, so it never reaches the gate and is never measured |
| Speech evidence is anchored to time | Alignment rewrites a text-only chunk's segments before assembly sees them, so a reading keyed to a segment's position would measure different words than it judges |
| The gate never fails a meeting, and unmeasured audio is not silent audio | The words are already safe as raw chunks. A meeting that cannot be measured assembles the way it did before this existed, and a segment timed past the end of the recording is kept |
| The opening words of a line that repeat the closing words of the previous one, across a chunk boundary and over shared time, are the overlap tail transcribed twice | 21 of 148 consecutive pairs on a 25-minute meeting repeated 3 to 17 words, 20 of them over shared time. Separate timecodes rendered it as a stutter; one paragraph per speaker renders it as nonsense |

The thresholds live in `SpeakerResolutionPolicy.shipping`, the diarizer and
decoder settings in `LocalDiarizationTuning`, `LocalTranscriptionTuning` and
`LocalAlignmentTuning`, the speech gate in `LocalSpeechPolicy`, and
`LocalConfigurationTests`, `SpeakerIdentityTests` and `SpeechGateTests` assert
them. `pipit-eval gate --meeting DIR` measures one meeting folder and prints
the three measures beside every segment on the local user's track with the
verdict, which is how those numbers get checked again on real audio.
`VoiceEvidenceTests` covers what a vector was derived from and what may be taken
back, `ReconnectTests` covers a call recorded in two halves, and
`TranscriptDivisionTests` and `TranscriptPanelTests` cover the boundaries a
person puts in a transcript and the paragraph they are put in. A change to any
of these numbers should fail a test before it reaches a user.

Four rules that an adversarial review found were easy to break by accident, each
now with a test:

- A meeting's own voices are not candidates for it. Without that guard a cluster
  matches the profile seeded from its own vector on a second pass, scores 1.0,
  and a voice heard once is announced as one heard before.
- An automatic pass never overwrites a speaker a person named. The occurrence
  upsert and `SpeakerMap.applySuggestion` both enforce it, from opposite ends.
- Work that happens because voice memory is on, rather than because the user
  chose a local backend, may wait for a model install but must never start one.
- Long pipeline calls go through `PipitRuntime.runProcessing`, not `enqueue`.
  The `enqueue` chain carries capture lifecycle actions and is what quit waits
  on, so a multi-minute job on it stops the next meeting being recorded.

## Capture invariants

These values were derived from measurements against real hardware, and changing
any of them changes verified behaviour. The numbers live in `CaptureThresholds`.

| Rule | Reason |
|---|---|
| Debounce configuration changes 400 ms before rebuilding | Bluetooth emits bursts of events, one of which reported 0 channels at 0 Hz mid-teardown |
| Suppress the watchdog 1.5 s after a rebuild starts | Without it the watchdog and the configuration observer produced 8 rebuilds in 5.8 s |
| Microphone watchdog on buffer arrival at 2 s | `engine.isRunning` stayed true with dead callbacks for minutes |
| Never adopt an unusable device format | Keep the last good format instead of rebuilding against 0ch/0Hz |
| Remote health uses `kAudioProcessPropertyIsRunningOutput`, 5 s fault threshold | A tap on an idle application delivers no callbacks at all, which is expected |
| Resolve tap targets by bundle-ID prefix on every poll | Slack Huddle audio lives in `com.tinyspeck.slackmacgap.helper`, and Firefox restarts under a new PID |
| Duration is `sum(frames / rate)` per segment | A Bluetooth switch to 16 kHz made the naive formula under-report by two thirds |
| Segments are CAF, rotated at 30 s | CAF survives `SIGKILL` intact; WAV under-reports its tail and M4A becomes unopenable |
| Capture starts at candidate into a memory ring | Slack opens the microphone 12.2 s before the user joins, and a Meet prejoin screen is invisible to native detection |
| One missing `Leave Huddle` read never ends a huddle | Slack's accessibility subtree reads empty intermittently during a live call |
| The browser extension can stop reporting without stopping a recording | Detection falls back to native signals, so a DOM change costs accuracy rather than the meeting |
| Sensor evidence is combined with native evidence and never replaces it | If a provider renamed its leave button, replacing native evidence would take a live meeting from confirmed to nothing |
| Detection reasserts a meeting on every poll | The session ends a recording whose evidence disappears, so a one-shot event would cut the call short |
| Only Pipit's own relay, launched by a browser, may use the sensor socket | The application holds the microphone grant, so a fabricated meeting event would produce a recording without a prompt |
| Content scripts are plain scripts and never ES modules | An `import` statement makes the whole script fail to load and the sensor silently never runs |
| No file I/O, manifest write or device work on an audio callback | An `fsync` on a render thread drops the audio being recorded |
| Every device build, teardown and poll runs on the capture control queue | Otherwise a poll-driven rebuild races a user-driven stop and leaves a live engine running |
| Echo cancellation disables ducking and falls back to plain capture if the voice unit refuses to build | Default ducking quiets the meeting audio being recorded, and the unit rejects some input/output pairings (virtual outputs, AirPods input with built-in output) |

Regression tests for these rules are in
`Sources/PipitTests/CaptureRecoveryTests.swift`, `DetectionTests.swift`,
`ManifestTests.swift` and `HardeningTests.swift`. A failure in one of them
indicates a behavioural regression. The last two rules, about audio callbacks and
the control queue, are structural: they are enforced by where the code lives
rather than by a test, so review changes to `CaptureEngine` and the segment
writers with them in mind. `docs/VERIFICATION.md` records what has been run
against real hardware and what has not.

## Architectural boundaries

- `PipitCore` imports only Foundation and holds every decision that can be
  made without I/O: recovery policy, session lifecycle, chunk planning,
  transcript assembly, manifest handling and storage layout. New logic belongs
  here by default.
- Provider adapters emit evidence. They do not start, stop or own recordings.
  `SessionController` is the only component that decides lifecycle.
- Transcription and diarization go through `TranscriptionBackend` and
  `DiarizationBackend` in `PipitCore`. Local and cloud implement the same
  protocols, chosen independently per meeting from settings, and neither is
  coupled to enrichment. Speaker memory is local in every configuration.
- `PipitSpeakers` owns every vector and knows nothing about what produced
  them. That is what lets a cloud diarizer's labels be embedded locally and
  resolved against the same store.
- The coordinators (`MicrophoneRecoveryCoordinator`, `RemoteTapCoordinator`) hold
  the recovery algorithms, and `PipitAudio` supplies AVFoundation and
  CoreAudio implementations behind `MicrophoneEngineController` and
  `ProcessTapController`. Tests drive the real algorithm through fakes instead of
  reimplementing it.
- Source audio, manifest lines, raw transcription and diarization output and
  imported originals are immutable once written. Titles, notes, the speaker map
  and metadata are mutable. Markdown files, `recording.m4a` and summaries are
  derived and can be regenerated.
- Source audio has two representations, and `metadata.audioArchive` says which
  one a meeting has; readers never infer it from what files exist. While a
  meeting records and processes, the source is float32 CAF segments under
  `raw/segments/`. After `complete`, compaction transcodes each track to
  `raw/audio/<track>.m4a` (AAC mono 16 kHz, the only rate any model reads),
  verifies the decoded duration against the manifest, records the archive in
  the metadata, and only then deletes the segments. Every failure mode leaves
  at least one verified copy: deletion is strictly after the metadata write,
  and an interrupted deletion resumes on the next launch sweep.
- `raw/speech.json` records what the recorded audio holds: the level of each
  quarter-second on both tracks and Silero's speech probability every 256 ms on
  the microphone. Derived from audio that never changes, so it is measured once
  and read on every assembly. Absent for meetings processed before it existed,
  and the assembler then keeps every segment.
- Speaker corrections are layers above immutable diarization: a cluster mapping,
  per-line overrides and the boundaries a person put in the transcript, all in
  `speakers.map.json`. A line override is anchored to a moment on the timeline
  rather than to an utterance identifier, because re-assembly and re-analysis
  move where turns begin and end. A `LineCut` is anchored the same way and for
  the same reason, and `MeetingStore.readCanonicalTranscript` applies the cuts
  on the way out, so every reader sees the same lines and `transcript.json`
  keeps holding what the assembler produced.
- Re-analysing speakers appends a diarization run and marks it active. The
  previous one stays on disk.
- `PipitSpeakers` records what every stored vector was derived from, in
  coordinates the application never rewrites: a recording, a track and time
  spans on the meeting timeline. Cluster and analysis identifiers travel
  alongside as context for a reader and decide nothing. That is what makes
  retraction a lookup rather than a reconstruction from whatever the clustering
  looks like now.
- A conversation recorded in two halves is a `LogicalMeeting` over two
  recordings, each immutable and complete on its own. The combined duration and
  transcript are derived on read; linking and separating write one field on each
  side and move no audio.
- The meetings window is the one place a past meeting is opened, corrected and
  read. It owns the list and one `MeetingReviewModel` at a time. That model owns
  reading and editing one meeting's files. Grouping, filtering and search are
  pure functions in `MeetingsDirectoryFilter`, so the sidebar's behaviour is
  tested without a window. The full-text search index is read in the background,
  again when the archive gains a meeting or a conversation gains or loses a
  recording, and one meeting's entry is dropped and read again when a change
  rewrites its `transcript.md`.
- A row's speakers are the clusters its `transcript.json` uses, named through
  its `speakers.map.json`. The map holds only the clusters that have a name, so
  a row built from the map alone shows no voices to name in exactly the meetings
  holding the most of them, and the Unnamed filter lists nothing. A cluster
  holding under `TranscriptSpeaker.audibleSeconds` is left out unless the map
  names it, which is the rule the speaker strip draws by. A diarizer can emit a
  label owning no transcript time, and counting one as a voice waiting for a
  name put a meeting under Unnamed with nothing in it to name.
- An imported recording's date comes from what the recorder said rather than
  from the copy. `RecordedDatePolicy` takes the container's creation date, then
  a timestamp in the filename, then the file's date on this Mac, refusing
  anything before 1990 or more than a day ahead. The filename outranks the
  filesystem because AirDrop, a download and a drag off a phone all stamp today.
  The manifest is still the authoritative timeline. It says how long the audio
  runs, and this says when it was recorded.
- Nothing before `audio_safe` sends data to OpenAI. Every stage after it is
  retryable, and until `complete` nothing deletes source audio. Compaction is
  the one deletion in the system, and it removes only a representation whose
  verified replacement is already recorded.

## Secrets

- The OpenAI key is stored in the login keychain only: not in preferences,
  meeting files, logs, fixtures, tests or CI.
- CI fails the build on anything shaped like an API key in the tree, and on any
  committed audio file.
- `plans/`, `probes/` and `.claude/specs/` hold local investigation material.
  They are gitignored and must stay untracked.

## Logging

`Log` in `PipitCore` exposes one logger per subsystem. Log lines carry
operational information only: identifiers, counts, durations, health states and
error categories. Meeting titles, transcripts, notes, participant names and
meeting URLs are content and are never logged. Errors are formatted through
`logSafeDescription`.

## Live API tests

Live tests are skipped unless explicitly enabled, so an ordinary run makes no API
calls:

```bash
./scripts/make-live-fixture.sh /tmp/pipit-fixture   # local `say`, free
PIPIT_LIVE_OPENAI=1 \
PIPIT_LIVE_FIXTURE=/tmp/pipit-fixture \
OPENAI_API_KEY=<your key> \
  ./scripts/test.sh --filter LiveOpenAI
```

The fixture is synthesised locally, so only the API requests are live.

The on-device tests are gated the same way and cost nothing but time and disk:

```bash
PIPIT_LOCAL_MODELS=1 \
PIPIT_LIVE_FIXTURE=/tmp/pipit-fixture \
  ./scripts/test.sh --filter LocalModels
```

The first run downloads about 650 MB. `pipit-eval` is the developer tool for
checking the measured numbers again on real audio:

```bash
swift run pipit-eval asr      --audio meeting.wav
swift run pipit-eval diarize  --audio meeting.wav --fa 0.07 --fa 0.20
swift run pipit-eval identity --audio andrew.wav --audio chris.wav
swift run pipit-eval voices
swift run pipit-eval gate     --meeting ~/Documents/Pipit/Meetings/2026/08/<id>
```
Assertions count how many expected terms survive transcription instead of
requiring exact wording, because synthetic speech transcribes with variation.

Two further opt-in suites exist. `PIPIT_LIVE_CAPTURE=1` records from the real
microphone and process tap, checks the manifest against the files on disk, and
runs a manual recording through `PipitRuntime`. `PIPIT_LIVE_LONG=1` puts an
hour of audio through the chunked pipeline; it costs money and takes tens of
minutes.

## Benchmarks

`pipit-eval bench` runs the real `ProcessingPipeline` over AMI meetings and
scores the meeting folder that comes out, so a change to transcription or
diarization is measured rather than argued about:

```bash
scripts/fetch-bench-audio.sh                    # audio into ~/Library/Caches/pipit-bench
scripts/eval.sh bench --suite ami-core --engine parakeet --engine cohere \
    --diarizer local --out /tmp/bench.json
scripts/eval.sh bench --case ES2002b --engine parakeet --baseline Benchmarks/baselines.json
```

The reference lives in `Benchmarks/`: ground-truth JSON per case, the pinned
checksums and the suite rosters. Audio is never committed and never in the
tree; the harness cuts each excerpt window from the cached recording with
AVFoundation. `scripts/make-bench-smoke.sh` synthesises a free two-voice
fixture for the same command via `--truth`, which catches wiring, chunk-seam
and assembly defects without touching the corpus.

The scorer is `PipitBench`, ported metric for metric from the Python scorer
the model-path probe validated. Attribution is reported twice: `attribution`
scores the best injective cluster mapping, where a cluster left over after
every reference speaker is claimed contributes nothing, and
`attributionMerged` scores the same after each leftover cluster is folded onto
the speaker it mostly covers. The baselines and the regression rule read the
strict one, so a diarizer that splits one voice into six is not paid for the
split.

`BenchScorerTests` puts transcripts with known answers through the meter: the
reference itself scores 0% WER and 100% attribution, the reference with one
word in ten deleted scores 10.1% WER, the reference with shuffled labels
scores at chance, and a hand-built six-cluster transcript over four speakers
scores 80% strict against 100% merged. A wrong meter is worse than no meter,
which is what those pin.

## Release

`docs/RELEASING.md` documents the full procedure. In summary: tag `vX.Y.Z`, and
`.github/workflows/release.yml` builds, tests, packages and drafts a GitHub
release. Signing and notarization run when the Apple secrets are configured and
are skipped with a warning when they are absent. Do not publish an unsigned build
as a release.
