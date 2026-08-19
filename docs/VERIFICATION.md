# Verification status

This file records which behaviour has been exercised and which has only been
implemented. An item is listed as verified only if it was run and its result
observed.

Machine: MacBook Pro (Mac14,9), Apple M2 Pro, macOS 27.0, Command Line Tools
only, no code-signing identity.

## Automated

`./scripts/test.sh` — 126 tests, all passing, no failures, in about 4 seconds.
Eleven further tests are skipped unless explicitly enabled, as described below.

`cd extension && npm test` — 10 tests, all passing.

CI runs the same two suites plus a release-configuration build, the application
bundling script, bundle verification, and repository hygiene checks on every
push. The last run on `main` is green.

Each row below covers a failure mode observed during development:

| Behaviour | Where |
|---|---|
| Configuration-burst debounce converges on one rebuild | `CaptureRecoveryTests` |
| Post-rebuild grace suppresses the watchdog, then releases it | `CaptureRecoveryTests` |
| Silent engine death caught by frame arrival | `CaptureRecoveryTests` |
| A transient 0ch/0Hz device is never adopted | `CaptureRecoveryTests` |
| A Bluetooth burst produces one rebuild instead of a storm | `CaptureRecoveryTests` |
| Remote idle counts as healthy; producing without callbacks rebinds | `CaptureRecoveryTests` |
| A replaced target process rebinds without ending the meeting | `CaptureRecoveryTests` |
| Mixed sample-rate duration sums per segment | `ManifestTests`, `AudioTests` |
| A truncated manifest tail is read as a crash tail | `ManifestTests` |
| A killed recording recovers into a usable interrupted meeting | `StorageTests` |
| Slack flapping and truncated reads never end a huddle | `DetectionTests`, `HardeningTests` |
| Slack is still detected without accessibility | `HardeningTests` |
| Meet and Zoom event orderings both reach the right state | `DetectionTests` |
| Extension loss falls back to native without ending the recording | `DetectionTests`, `SessionTests` |
| Chunk overlap is de-duplicated | `ProcessingTests` |
| Renaming a speaker re-renders without modifying raw diarization | `ProcessingTests`, `PipelineTests` |
| An API failure keeps the audio and stays retryable | `PipelineTests` |
| A rate limit is retried automatically, then bounded after three attempts | `PipelineTests` |
| Each track is placed on the meeting timeline at its own start | `PipelineTests` |
| A phrase repeated inside one chunk is not treated as overlap | `ProcessingTests` |
| Remote audio arriving after commit is still written | `HardeningTests` |
| An unsupported call keeps recording for as long as it runs | `HardeningTests` |
| Only MeetTape's own relay, launched by a browser, may connect | `HardeningTests` |
| An application installed beside a browser is not accepted as one | `HardeningTests` |
| An unknown call arms the ring before it is confirmed | `DetectionTests` |
| A provider change between candidate and confirm retargets the tap | `SessionTests` |
| Starting a recording by hand during a candidate keeps the pre-roll | `SessionTests` |
| A prejoin screen the extension can see is not committed | `DetectionTests` |
| A call in one state still reports inside the freshness window | `extension/test` |
| A three-channel microphone reads back audible, not silent | `AudioTests` |
| A writer that cannot open its file does not hang capture | `HardeningTests` |
| Recovery can append to a manifest cut off mid-line | `ManifestTests` |
| A device that stays away is retried with a backoff | `CaptureRecoveryTests` |
| A rename during processing is not overwritten by a stage | `PipelineTests` |
| Every panel builds and lays out against a real view tree | `UITests` |
| Choosing a new storage folder takes effect without a relaunch | `UITests` |

## Exercised against real hardware and the real API

**Capture chain.** `MEETTAPE_LIVE_CAPTURE=1 ./scripts/test.sh --filter LiveCapture`
runs the shipping `CaptureEngine` with `AVAudioEngine` and a CoreAudio process
tap for ten seconds. Verified: microphone audio recorded, segments rotated, the
manifest closed with no open segments, every segment's frame count matching the
file on disk, and the pre-roll captured before commit flushed into the recording.

**Manual recording through the runtime.** The same command runs a second live
test that drives `MeetTapeRuntime` instead of the engine directly. It starts a
manual recording, captures for nine seconds, stops, and waits for the archive.
Verified: one meeting directory written under the configured storage root with
source `manual`, the manifest closed with no open segments, nine seconds of
microphone audio in rotating segments whose frame counts match the files, a
meeting duration matching the capture, and processing reaching `audio_safe`. With
no key in the keychain, processing then fails at the first API call with a
missing-credential error while the recording remains intact, which is the
guarantee the `audio_safe` boundary provides.

**The packaged application.** Built with `scripts/bundle-app.sh`, launched, and
observed: `menu bar item ready: true, visible: true` and `browser sensor server
listening` in the log, `lsappinfo` reporting `type="UIElement"` so the
application has no Dock presence, and the native messaging host, its Firefox
manifest and the sensor socket all present in Application Support.

**A recording driven by a sensor event, end to end.** Before peer verification
was added, a simulated `in_call` event over the socket produced a Google Meet
meeting: 65 seconds of microphone audio in three rotating 30-second CAF segments,
the Firefox tap reporting `idle_but_bound` while Firefox was silent, and the
meeting ID and URL from the event stored in `metadata.json`.

**Crash recovery on real files.** That recording was then killed with `pkill`. On
the next launch the application adopted the crash tail of 5.1 s from the open
segment, reconstructed a segment the manifest had never recorded, reported a
total of 65.1 s from per-segment accounting, and moved the meeting to
`audio_safe`.

**The native messaging relay.** A host process connected to the application's
socket, relayed length-prefixed browser messages as newline-delimited JSON, and
the application logged connect and disconnect. After peer verification was added,
the same test is refused with "the relay was not launched by a browser", which is
the intended behaviour.

**A 32-minute capture soak.** `MEETTAPE_SOAK_MINUTES=30 ./scripts/test.sh --filter Soak`
ran the shipping `CaptureEngine` against real hardware for 1944 seconds: 65
segments written and closed, resident memory 29 MB at the start and 29 MB at the
end, zero engine restarts, and every segment's manifest frame count matching the
file on disk.

**Live OpenAI.** `MEETTAPE_LIVE_OPENAI=1` with a locally synthesised
three-speaker fixture. Six tests pass: credential and model access, transcription
with segment timings, diarization separating two remote speakers, the assembled
transcript keeping the microphone track as the local user and the remote track
namespaced per chunk, speaker resolution naming Chris and Tim from their
self-introductions, and enrichment producing a title and a summary.

**A full import through the real API.** `LiveEndToEnd` imports the fixture, runs
the whole pipeline, and checks the archive: processing reaches `complete`, the
transcript contains several speakers and no local-user claim, since an import has
no microphone track, `transcript.md` and `summary.md` exist, the original file is
preserved byte for byte, and the user's notes are unmodified.

**Long-meeting processing.** `MEETTAPE_LIVE_LONG=1` put a 65-minute recording
through the chunked pipeline against the live API, taking 30 minutes. Verified:
the recording was chunked, no chunk exceeded the model's 1400-second duration
limit, raw speaker labels stayed distinct per chunk, canonical timestamps stayed
monotonic across chunk boundaries, the transcript spanned the recording, and the
overlap between chunks produced no duplicated utterances. The run costs money and
takes tens of minutes, so it is excluded from an ordinary test run.

## Not verified

The following behaviour is implemented but has not been exercised, and should not
be assumed to work.

- **A real Slack Huddle.** The `Leave Huddle` detection, its flap handling and
  the helper-process tap are covered by tests written against recorded
  observations, but no huddle has been held against this build.
- **A real Google Meet or Zoom call in Firefox** with the extension loaded from
  `extension/dist/firefox`. The sensor path was verified with a synthetic relay
  before peer verification was added, and the browser-launched path has not been
  run.
- **Chrome.** The extension builds and its manifest parses, but MV3 service
  workers suspend when idle and no Chrome session has been observed. The Chrome
  native messaging manifest is not installed, because it requires the packed
  extension's ID.
- **A two-hour soak.** The longest continuous capture so far is 32 minutes, with
  flat memory and no restarts.
- **Sleep, wake and lock during a recording.** The wake path has unit coverage
  through the coordinators' settle delay and has not been exercised on hardware.
- **A Bluetooth device switch mid-recording.** The rebuild-storm mitigation is
  covered by tests that reproduce the measured event sequence, rather than by
  reconnecting a headset against this build.
- **Notifications.** macOS refuses to deliver notifications under an ad-hoc
  signature, so neither the notices nor the actionable "Keep recording?" buttons
  have been seen. This requires a Developer ID signature.
- **Gatekeeper, notarization and Homebrew.** No signing identity exists on this
  machine. See `docs/RELEASING.md`.
- **The appearance of the windows.** Onboarding, settings and review are built
  and laid out in `UITests` through `NSHostingController`, which catches a view
  that traps at runtime but says nothing about layout quality. No screenshot pass
  or manual walkthrough of the panels has been done.
- **FaceTime.** Not implemented as a provider. A FaceTime call would be detected
  only through the generic path, if at all.
- **Calendar matching.** `CalendarService` reads EventKit and scores events
  against a recording's time window, and it has no tests and has not been run
  against a real calendar. A wrong match shows the wrong title and attendees on a
  meeting; the recording and transcript are unaffected.
