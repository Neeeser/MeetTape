# Architecture

Pipit runs as a single process. Detection, capture, storage and processing are
separate subsystems within it, and the boundaries between them are enforced in
the module structure.

## Modules

```
PipitApp            LSUIElement executable; owns the application delegate
 └── PipitUI        menu bar, onboarding, settings, meeting review
      └── PipitServices     runtime wiring, processing pipeline
           ├── PipitDetection    accessibility, window titles, sensor socket
           ├── PipitIntegrations OpenAI, Keychain, EventKit, notifications
           ├── PipitLocalAI      WhisperKit, FluidAudio, model management
           ├── PipitSpeakers     SQLite voice identity store
           ├── PipitAudio        AVAudioEngine, process taps, files
           └── PipitCore         pure logic, Foundation only
pipit-nativehost    compiled relay between the browser and the application
pipit-eval          developer tool; not in the bundle
```

`PipitSpeakers` does not depend on `PipitLocalAI`. The store holds vectors
and knows nothing about what produced them, which is what lets a cloud diarizer's
labels be embedded locally and resolved against the same memory.

`PipitCore` imports only Foundation. Every decision that can be made without
I/O is made there, which keeps the interesting failure modes reproducible in unit
tests.

## Two-stage promotion

Capture is promoted through two stages because of two measurements taken during
development: Slack opens the microphone about twelve seconds before the user
joins a Huddle, and a Google Meet prejoin screen is indistinguishable from an
active call when observed from outside the browser.

```
CANDIDATE   a provider looks active
            → start BOTH sources, write only into a 15 s memory ring
CONFIRMED   Slack: the "Leave Huddle" control exists
            browser: the extension reports in_call
            fallback: the microphone held past a dwell on a provider page
            → create the meeting directory, flush the ring, write segments
ENDED       provider end plus a grace period
            → finalise, or discard if the call was never confirmed
```

The ring buffer uses about 5.5 MiB and roughly a microsecond per callback, which
makes it cheap enough to run for every candidate. An abandoned prejoin screen
leaves no directory on disk, and a confirmed meeting includes its opening
sentence.

## Capture

```
AVAudioEngine ──▶ MicrophoneRecoveryCoordinator ──▶ SegmentWriter(mic)
                        │                                   │
                   MicRecoveryPolicy                   manifest.jsonl
                        │                                   │
CoreAudio tap ──▶ RemoteTapCoordinator ─────────────▶ SegmentWriter(system)
                        │
                 RemoteRecoveryPolicy
```

The policies are pure state machines. They receive buffer arrivals, configuration
changes and poll ticks, and decide whether the source should be rebuilt. The
coordinators drive them through protocols (`MicrophoneEngineController`,
`ProcessTapController`) that AVFoundation and CoreAudio implement in production
and that fakes implement in tests, so the rebuild-storm regression is covered by
a unit test instead of a hardware exercise.

Buffers are copied inside the audio callback and handed to a private serial
queue. Opening a segment file happens on that queue as well, because the first
remote packet arrives on a render thread and creating a file there, with the
manifest `fsync` that follows it, drops the audio being recorded. No file I/O happens on a render thread, and no reference to a tap buffer
escapes its callback. Health changes follow the same rule: appending to the
manifest performs `write` and `fsync`, so the coordinators' callbacks hop to the
control queue before reporting.

Every operation that builds or tears down a device runs on that one control
queue: arming, committing, stopping, retargeting and the 500 ms poll. This makes
a poll-driven rebuild racing a user-driven stop impossible, and it guarantees
that stopping a recording cannot leave a live engine or tap behind.

The remote writer is opened when the first remote packet arrives rather than at
commit time. A provider's audio process often does not exist at the moment a
meeting is confirmed, and a writer that was never created would silently discard
every packet for the rest of the meeting while the tap reported healthy.

### Microphone and remote health models

The two sources fail in different ways, so they are monitored differently.

The microphone has one healthy state: buffers are arriving. Absence of buffers is
always a fault, and the only complication is avoiding false positives during a
rebuild or a configuration burst.

A process tap has two healthy states. When the tapped application produces no
audio it delivers no callbacks at all, indefinitely, and that is correct
behaviour. The signal that makes the state decidable is the application's own
`kAudioProcessPropertyIsRunningOutput`:

```
no target process              → degraded, source gone, keep polling
target exists, not producing   → idleButBound, silence is expected
producing + callbacks          → healthy
producing + no callbacks       → failed, rebind
```

Only the last case is a fault. Applying the microphone watchdog here would report
a quiet meeting as broken whenever nobody spoke.

## The manifest as timeline

Audio container headers are not trusted. Every segment open, close, format
change, restart, health transition and marker is appended to
`raw/manifest.jsonl` and flushed with `fsync`, so a hard kill loses at most
a partial final line, which the reader tolerates.

Duration is the sum of each segment's own frame count over that segment's own
sample rate. A Bluetooth profile switch drops the input to 16 kHz mid-meeting,
and dividing an accumulated frame count by the current sample rate under-reported
a real twelve-minute session by nearly two minutes.

Startup recovery walks every incomplete meeting, adopts any segment that has an
open record and no close record by reading its real length from the file, and
reconstructs segments that the manifest never recorded. A recording killed by a
crash becomes an interrupted meeting that still processes.

## Session lifecycle

```
idle ──▶ candidate ──▶ recording ──▶ reconnecting ──▶ ended
             │              │              │
          discard        run 1..n      run 2 appended
```

A meeting and a recording are separate objects. A disconnect within the reconnect
window keeps the meeting and appends a second run, and source segments are never
rewritten to merge anything. Two meetings that turn out to be the same call are
linked afterwards by `ReconnectMatcher`, which merges automatically only on
strong evidence and otherwise presents the match as a suggestion.

The reconnect window itself is not recorded. When the evidence disappears the
segments close, capture falls back to the 15-second memory ring, and the menu
bar shows a distinct disconnected state instead of the recording indicator. A
rejoin opens new segments, numbered after the previous run's, and flushes the
ring so the moments before the rejoin was confirmed are on disk. Candidate
evidence sustains a recording only when it comes from the meeting's own
provider; another application idling with the microphone cannot hold a
recording open.

Evidence that ends is still subject to two graces before the window starts: 12
seconds after a browser releases the microphone, because a page refresh drops
it briefly, and a 6-second end grace against detection flaps. Those few seconds
are the only non-meeting audio a recording can carry.

A manually started recording ignores provider state entirely, and no detector
observation can end it.

## Processing

```
recording → finalizing → audio_safe → transcribing → diarizing
          → resolving_speakers → enriching → complete
                                          ↘ failed (resumable at the failed stage)
```

Each of the first two work-doing stages picks a backend from settings, and the
two choices are independent. A backend declares whether it needs its audio
chunked; the cloud endpoints do, because they reject audio past 1400 seconds and
bodies past 25 MiB, and the local ones do not. A backend also declares whether it
returns the words as well as the speakers: the cloud diarizer does both in one
request, so the diarized track needs no separate transcription, while the local
diarizer decides speakers only.

One meeting is processed at a time and a job waits between stages while a
recording is live. Transcription is 92% of the work and both local models target
the Neural Engine, so a second concurrent meeting takes time from the first
rather than adding any. The gate reads the recording state from a lock-protected
box rather than hopping to the main actor, which is the same pattern the settings
snapshot uses and for the same reason: `MainActor.assumeIsolated` from an actor's
executor is a runtime trap.

`audio_safe` is the boundary between capture and network work. Nothing is sent to
OpenAI before it, and every stage after it can be retried without risking the
recording. Each transition is written to `metadata.json` before the next stage
starts, and each completed chunk is appended to `transcript.raw.json` as it
arrives, so a resumed run does not repeat work that already succeeded.

A rate limit, a server error or a transport failure is retried in place, using
the server's `Retry-After` when it sends one, up to three attempts per stage.
After that the meeting waits for the user, who can retry it from the meetings
window or from the notification.

The two tracks do not start at the same instant, and a chunk's offset is a
position inside one track's audio. The track's lead-in, meaning the delay between
the first frame of the earliest track and the first frame of this one, is added
when the chunk is recorded. The mixdown pads the later track with the same amount
of silence, so `recording.m4a` and the transcript agree.

### On-device processing

```
transcription   WhisperKit, openai_whisper-large-v3-v20240930_turbo_632MB
                skipSpecialTokens = true, wordTimestamps = true
                no prompt conditioning, no VAD chunking
diarization     FluidAudio OfflineDiarizerManager, the offline VBx pipeline
                clustering.warmStartFa = 0.20
embeddings      the same pipeline's 256-d chunk embeddings, free with diarization
```

Four of those are load-bearing rather than preferences.

`skipSpecialTokens` defaults to false, which leaks `<|startoftranscript|><|en|>`
into the transcript text.

Prompt conditioning is absent because it improves punctuation and destroys word
timings: on a 60-second clip, 198 distinct word starts became 153, with 43 words
reporting zero duration and 16 collapsed onto a single timestamp. Word timings
are what speaker attribution consumes, and punctuation is recoverable later while
timings are not.

VAD chunking is absent because it was 15% faster over 65 minutes and dropped 231
of 9278 words, and produced a segment whose start went backwards. WhisperKit's
own long-file handling held timestamps monotonic over the same file.

`warmStartFa` is the VBx acoustic scaling and the library ships 0.07, which
under-counts badly above eight speakers. Over 32 recordings of 2 to 21 speakers
the default found 8 where there were 17 and left 35.4% of reference speakers
without a cluster. At 0.20: DER 6.22% to 4.06%, JER 51.3% to 30.7%, mean
speaker-count error at ten or more speakers 6.25 to 1.38, word attribution 92.8%
to 95.5%, and 11.9% of speakers lost. The value is tuned on VoxConverse, which is
broadcast panels rather than conference calls, so it is a measured default and
not a solved constant. It lives in `LocalDiarizationTuning`, and a test asserts
it.

`clustering.numSpeakers` is never set automatically, from any source. The tuned
automatic configuration beat the exact true speaker count on word attribution
(95.5% against 94.4%), on merges a user has to perform (0.8 against 2.2 per
recording) and on speakers recovered (11.9% lost against 21.1%). A participant
list and a calendar attendee count are worse than not asking, and both are
usually wrong in the expensive direction: an invited-but-silent attendee inflates
the count, and under-counting cannot be undone with a merge. The field is reached
only by the manual "Re-analyze Speakers" control, where the number is the user's
and is under their review.

Models install under `~/Library/Application Support/Pipit/Models`. WhisperKit
defaults to `~/Documents/huggingface`, which puts 624 MB where Finder shows it
and iCloud Drive syncs it, so `downloadBase` is set explicitly. Loading also
passes `modelFolder` explicitly on every load, because WhisperKit with
`download: false` does not resolve its own download cache and fails with "Model
folder is not set"; without it an installed, offline machine is a broken one.

### Attribution

The transcriber produces words with timings and the diarizer produces intervals.
Each word goes to the interval it overlaps most, then to the nearest interval
within half a second, then nowhere. Measured over a 15-minute call: 96.3% landed
by overlap, 1.2% by the fallback, 2.5% went unattributed and 0.1% straddled a
boundary. The unattributed remainder is backchannels spoken over another speaker,
which the diarizer drops and the transcriber keeps, so they stay with the words
around them rather than being dropped or invented into a speaker.

A track whose transcript segments already name a speaker keeps them. That is the
cloud diarizer's own output, and re-deriving it from intervals would change a
working result for nothing.

### Speaker identity

Six concepts, four layers, one identifier space.

```
RawClusterAssignment    diarization.raw.json, immutable
ClusterIdentityMapping  speakers.map.json entries, mutable
UtteranceIdentityOverride  speakers.map.json overrides, mutable
RenderedIdentity        derived at read time, never stored
```

Named people and recurring unnamed voices share one identifier space, so naming a
voice later is a single row update: every occurrence, cluster mapping and
utterance override already points at the right identifier and none of them has to
be rewritten. A merge sets a redirect rather than deleting anything, and reads
follow it, so undoing a merge is clearing one column.

A line-level correction is anchored to a moment on the timeline rather than to an
utterance identifier, because re-assembling the transcript or re-analysing
speakers moves where turns begin and end. The moment the user corrected stays
inside whichever line covers it.

Correction precedence, enforced when an assignment is written rather than when it
is read:

```
utterance-level human override
  > cluster-level human mapping
  > mic-track deterministic identity
  > voice recognition at High
  > anonymous recognition at "seen before"
  > textual suggestion
  > Unknown
```

Recognition needs score, margin and duration together: at least 0.70 similarity,
at least 0.10 of margin over the runner-up, and at least 45 seconds of speech.
Over 326 verified-distinct speakers that produced zero wrong automatic names at
97.9% recall, where a score rule alone would have named the wrong person: the
worst impostor there scored 0.957 against the true speaker's own 0.951. Linking a
recurring unnamed voice uses 0.75 rather than 0.70, because the false-link rate
for a genuinely new voice grows with pool size where named matching does not.

Only the microphone track of a remote call and an explicit human confirmation may
write a vector into a profile. A recognition result, at any confidence, is a
read. Without that rule a wrong automatic match widens the profile it matched
against and the error compounds.

Vectors live in `~/Library/Application Support/Pipit/Speakers/voices.sqlite`,
as Float32 blobs with no vector index: a full scan of 100,000 embeddings measured
1.6 ms and the realistic store for 100 named people plus 500 recurring voices is
3.1 MB. Scoring is against a derived centroid only. Taking a maximum over
individual exemplars lifted genuine scores from 0.721 to 0.737 and impostor
scores from 0.464 to 0.543, costing a quarter of the margin. The raw vectors are
kept for re-deriving the centroid and for a future model migration, and are not
used at query time.

Nothing biometric is written into a meeting folder. `diarization.raw.json`
carries intervals and speech durations and deliberately no vectors, because the
meeting folder is what a user copies, syncs and shares.

### Speakers

On a remote call the microphone track contains only the local user, so it is
transcribed and never diarized. Only the remote track is diarized. Measured on a
three-speaker sample, diarizing the remote track alone scored 97% against 84% for
diarizing a mixdown of both tracks, and the local speaker is identified by
construction.

A user without headphones plays the remote side through speakers, and the
microphone records it: the transcription model then writes the remote speakers'
words onto the local track under the local user's name. The remote track is
authoritative for those words, so during assembly a local-track segment whose
text matches a diarized utterance nearby in time is dropped as echo. The match
window is generous because timestamps drift by whole sentences on audio with
speaker bleed, and a segment in which the model merged both voices cannot be
split, so headphones still produce the cleaner transcript. Turns are also
capped at 30 seconds: bleed keeps the microphone from ever going silent, and
the pause rule alone chained a real recording into one 219-second utterance
that pushed every reply after the whole block.

Anonymous labels are namespaced per chunk (`remote_chunk_002_speaker_01`) because
the API's labels are stable only within a single request, and an unnamed label
renders with its chunk ("Speaker 1 (part 2)") so two clusters are never displayed
as one person. Mapping several raw
clusters onto one person is the job of the speaker-resolution stage, whose output
is a suggestion stored in `speakers.map.json`. An assignment made by the user
takes precedence, and renaming re-renders the Markdown without another API
request.

An in-person or imported recording has a single track containing every speaker,
so it is diarized and keeps its raw labels.

### Long meetings

The diarization endpoint rejects audio longer than 1400 seconds and request
bodies larger than 25 MiB. Chunks target 19 minutes, and each boundary is moved
to the quietest point within a minute either side using an energy profile.
Adjacent chunks overlap by eight seconds so that a sentence crossing a boundary
survives, and the overlap is de-duplicated by text similarity when the canonical
transcript is assembled.

Chunks are independent requests and are sent three at a time. The endpoint
processes long audio at close to real time, so sending chunks one after another
made a 25-minute import take over ten minutes. Each result is committed to disk
as it arrives, and an interrupted run resumes at the chunks that never landed.

## Browser sensor

```
content script → background → connectNative → pipit-nativehost
                                                     │  JSON lines
                                              Unix domain socket
                                                     │
                                          BrowserSensorServer (app)
```

The extension reads semantic signals only: URL structure and accessibility
labels, never CSS class names. The host is a compiled binary because browsers
spawn hosts with a minimal `PATH`, and it is installed in Application Support
because a host placed under a TCC-protected directory never launches.

Sensor evidence is combined with native evidence, and the stronger of the two
determines the state. If a provider renamed its leave button, substituting sensor
evidence for native evidence would take a live meeting from confirmed to nothing.
State is tracked per tab, so a second tab opened during a call cannot overwrite
the state of the tab that is in the call, and an event older than the one already
held is ignored.

When the extension goes quiet, detection falls back to native signals and an
in-flight recording continues, so losing the extension costs accuracy rather than
the recording.

The application accepts a socket connection only from its own relay binary when
that binary was launched by a browser. Pipit holds the microphone and
system-audio grants, so a process able to send a fabricated meeting event could
obtain a recording without triggering a permission prompt of its own.

Firefox routes every tab through one CoreAudio object, so meeting audio cannot be
separated from a video playing in another tab. The extension reports how many
other tabs are audible, the meeting is flagged accordingly, and recording is
never delayed or blocked because of it.
