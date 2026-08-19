# Architecture

MeetTape runs as a single process. Detection, capture, storage and processing are
separate subsystems within it, and the boundaries between them are enforced in
the module structure.

## Modules

```
MeetTapeApp            LSUIElement executable; owns the application delegate
 └── MeetTapeUI        menu bar, onboarding, settings, meeting review
      └── MeetTapeServices     runtime wiring, processing pipeline
           ├── MeetTapeDetection    accessibility, window titles, sensor socket
           ├── MeetTapeIntegrations OpenAI, Keychain, EventKit, notifications
           ├── MeetTapeAudio        AVAudioEngine, process taps, files
           └── MeetTapeCore         pure logic, Foundation only
meettape-nativehost    compiled relay between the browser and the application
```

`MeetTapeCore` imports only Foundation. Every decision that can be made without
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
`segments/manifest.jsonl` and flushed with `fsync`, so a hard kill loses at most
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

A manually started recording ignores provider state entirely, and no detector
observation can end it.

## Processing

```
recording → finalizing → audio_safe → transcribing → diarizing
          → resolving_speakers → enriching → complete
                                          ↘ failed (resumable at the failed stage)
```

`audio_safe` is the boundary between capture and network work. Nothing is sent to
OpenAI before it, and every stage after it can be retried without risking the
recording. Each transition is written to `metadata.json` before the next stage
starts, and each completed chunk is appended to `transcript.raw.json` as it
arrives, so a resumed run does not repeat work that already succeeded.

A rate limit, a server error or a transport failure is retried in place, using
the server's `Retry-After` when it sends one, up to three attempts per stage.
After that the meeting waits for the user, who can retry it from the review panel
or from the notification.

The two tracks do not start at the same instant, and a chunk's offset is a
position inside one track's audio. The track's lead-in, meaning the delay between
the first frame of the earliest track and the first frame of this one, is added
when the chunk is recorded. The mixdown pads the later track with the same amount
of silence, so `mixed.caf` and the transcript agree.

### Speakers

On a remote call the microphone track contains only the local user, so it is
transcribed and never diarized. Only the remote track is diarized. Measured on a
three-speaker sample, diarizing the remote track alone scored 97% against 84% for
diarizing a mixdown of both tracks, and the local speaker is identified by
construction.

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

## Browser sensor

```
content script → background → connectNative → meettape-nativehost
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
that binary was launched by a browser. MeetTape holds the microphone and
system-audio grants, so a process able to send a fabricated meeting event could
obtain a recording without triggering a permission prompt of its own.

Firefox routes every tab through one CoreAudio object, so meeting audio cannot be
separated from a video playing in another tab. The extension reports how many
other tabs are audible, the meeting is flagged accordingly, and recording is
never delayed or blocked because of it.
