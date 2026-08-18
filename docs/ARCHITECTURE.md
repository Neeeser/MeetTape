# Architecture

MeetTape is one process. Detection, capture, storage and processing are separate
subsystems inside it, and the boundaries between them are load-bearing rather
than decorative.

## Modules

```
MeetTapeApp            LSUIElement executable; owns nothing but the delegate
 └── MeetTapeUI        menu bar, onboarding, settings, meeting review
      └── MeetTapeServices     runtime wiring, processing pipeline
           ├── MeetTapeDetection    accessibility, window titles, sensor socket
           ├── MeetTapeIntegrations OpenAI, Keychain, EventKit, notifications
           ├── MeetTapeAudio        AVAudioEngine, process taps, files
           └── MeetTapeCore         pure logic, Foundation only
meettape-nativehost    compiled relay between the browser and the app
```

`MeetTapeCore` has no AppKit, no AVFoundation and no network. Everything that can
be decided without I/O is decided there, which is why the interesting failure
modes are reproducible in a test.

## The two-stage promotion

This is the central design idea, and it exists because of two measurements:
Slack opens the microphone about twelve seconds before the user joins a Huddle,
and a Google Meet prejoin screen is byte-identical to an active call from
outside the browser.

```
CANDIDATE   a provider looks active
            → start BOTH sources, write only into a 15 s memory ring
CONFIRMED   Slack: the "Leave Huddle" control exists
            browser: the extension reports in_call
            fallback: the microphone held past a dwell on a provider page
            → create the meeting directory, flush the ring, write segments
ENDED       provider end plus a grace period
            → finalise, or discard if it was never confirmed
```

The ring costs about 5.5 MiB and roughly a microsecond per callback, which is
what makes "always capture, commit later" affordable. An abandoned prejoin leaves
no directory behind; a confirmed meeting still contains its opening sentence.

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

The policies are pure state machines: they receive buffer arrivals, configuration
changes and poll ticks, and answer one question, "rebuild or not". The
coordinators drive them against protocols (`MicrophoneEngineController`,
`ProcessTapController`) that AVFoundation and CoreAudio implement in production
and fakes implement in tests. The rebuild-storm regression is therefore a unit
test, not a hardware exercise.

Buffers are copied inside the audio callback and handed to a private serial queue.
No file I/O happens on a render thread, and no reference to a tap buffer escapes
its callback.

### Why the microphone and the remote source differ

They fail differently, so they are monitored differently.

The microphone has exactly one healthy state: buffers are arriving. Absence of
buffers is always a fault, and the only complication is not mistaking a rebuild
or a configuration burst for one.

A process tap has two healthy states. When the tapped application is silent it
delivers no callbacks at all, indefinitely, and that is correct. The decidable
signal is the application's own `kAudioProcessPropertyIsRunningOutput`:

```
no target process              → degraded, source gone, keep polling
target exists, not producing   → idleButBound, silence is expected
producing + callbacks          → healthy
producing + no callbacks       → failed, rebind
```

Only the last line is a fault. Reusing the microphone watchdog here would report a
quiet meeting as broken every time nobody spoke.

## The manifest is the timeline

Audio container headers are not trusted. Every segment open, close, format change,
restart, health transition and marker is appended to `segments/manifest.jsonl`
and flushed with `fsync`, so a hard kill loses at most a partial final line, which
the reader tolerates.

Duration is the sum of each segment's own frames over that segment's own sample
rate. This is not pedantry: a Bluetooth profile switch drops the input to 16 kHz
mid-meeting, and dividing an accumulated frame count by the current rate
under-reported a real 12-minute session by nearly two minutes.

Startup recovery walks every incomplete meeting, adopts any segment that has an
open record and no close record by reading its real length from the file, and
reconstructs segments the manifest never recorded at all. A killed recording
becomes an interrupted meeting that still processes; it is never discarded.

## Session lifecycle

```
idle ──▶ candidate ──▶ recording ──▶ reconnecting ──▶ ended
             │              │              │
          discard        run 1..n      run 2 appended
```

A meeting and a recording are different objects. A disconnect inside the
reconnect window keeps the meeting and appends a second run; source segments are
never rewritten to merge anything. Two separate meetings that turn out to be one
are linked afterwards through `ReconnectMatcher`, which merges automatically only
on strong evidence and otherwise asks.

A manually started recording ignores provider state entirely. Nothing a detector
observes can end it.

## Processing

```
recording → finalizing → audio_safe → transcribing → diarizing
          → resolving_speakers → enriching → complete
                                          ↘ failed (resumable at the failed stage)
```

`audio_safe` is the boundary. Nothing reaches OpenAI before it, and after it every
stage is retryable without risking the recording. Each transition is written to
`metadata.json` before the next stage starts, and each completed chunk is
appended to `transcript.raw.json` as it arrives, so a resumed run never re-sends
work that already succeeded.

### Speakers

The microphone track on a remote call is the local user by construction, so it is
transcribed and never diarized. Only the remote track is diarized. Measured on a
three-speaker sample, diarizing the remote track alone scored 97% against 84% for
diarizing the mix, and the local speaker is exact by construction rather than
merely likely.

Anonymous labels are namespaced per chunk (`remote_chunk_002_speaker_01`) because
the API's labels are only stable within one request. Mapping several raw clusters
onto one person is the speaker-resolution stage's job, and its output is a
suggestion stored in `speakers.map.json`. A human assignment always wins, and
renaming re-renders the Markdown without another request.

An in-person or imported recording has one track holding everyone, so it is
diarized and keeps its raw labels.

### Long meetings

The diarization endpoint rejects audio longer than 1400 seconds and bodies larger
than 25 MiB. Chunks target 19 minutes, and each boundary is nudged to the quietest
point within a minute either side using a simple energy profile. Adjacent chunks
overlap by eight seconds so a sentence crossing a boundary survives, and the
overlap is de-duplicated by text similarity when the canonical transcript is
assembled.

## Browser sensor

```
content script → background → connectNative → meettape-nativehost
                                                     │  JSON lines
                                              Unix domain socket
                                                     │
                                          BrowserSensorServer (app)
```

The extension reads semantic signals only: URL shape and accessibility labels,
never CSS class names. The host is a compiled binary because browsers spawn hosts
with a minimal `PATH`, and it lives in Application Support because a host under a
TCC-protected directory never launches at all.

The sensor is authoritative only while fresh. When it goes quiet the detector
falls back to native signals, and an in-flight recording keeps running. Losing the
extension costs precision, never the meeting.

Firefox routes every tab through one CoreAudio object, so meeting audio cannot be
separated from a video playing in another tab. The extension reports how many
other tabs are audible and the meeting is flagged; recording is never delayed or
blocked for it.
