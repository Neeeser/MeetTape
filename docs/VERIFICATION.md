# What has actually been verified

This file distinguishes what was exercised from what was only implemented. It is
deliberately conservative: an item is only listed as verified if it was run and
its result observed.

Machine: MacBook Pro (Mac14,9), Apple M2 Pro, macOS 27.0, Command Line Tools
only, no code-signing identity.

## Automated

`./scripts/test.sh` — 112 tests, all passing, no failures, in about 3 seconds.
Eleven further tests are skipped unless explicitly enabled (see below).

`cd extension && npm test` — 9 tests, all passing.

CI runs the same two suites plus a release-configuration build, the app bundling
script, bundle verification, and repository hygiene checks on every push. The
last run on `main` is green.

Coverage worth naming, because each one encodes a measured failure:

| Behaviour | Where |
|---|---|
| Configuration-burst debounce converges on one rebuild | `CaptureRecoveryTests` |
| Post-rebuild grace suppresses the watchdog, then releases it | `CaptureRecoveryTests` |
| Silent engine death caught by frame arrival | `CaptureRecoveryTests` |
| A transient 0ch/0Hz device is never adopted | `CaptureRecoveryTests` |
| A Bluetooth burst produces one rebuild, not a storm | `CaptureRecoveryTests` |
| Remote idle is healthy; producing without callbacks rebinds | `CaptureRecoveryTests` |
| A replaced target process rebinds without ending the meeting | `CaptureRecoveryTests` |
| Mixed sample-rate duration sums per segment | `ManifestTests`, `AudioTests` |
| A truncated manifest tail is a crash tail, not corruption | `ManifestTests` |
| A killed recording recovers into a usable interrupted meeting | `StorageTests` |
| Slack flapping and truncated reads never end a huddle | `DetectionTests`, `HardeningTests` |
| Slack without accessibility is still detected | `HardeningTests` |
| Meet and Zoom event orderings both reach the right state | `DetectionTests` |
| Extension loss falls back to native without ending the recording | `DetectionTests`, `SessionTests` |
| Chunk overlap is de-duplicated | `ProcessingTests` |
| Renaming a speaker re-renders without touching raw diarization | `ProcessingTests`, `PipelineTests` |
| An API failure keeps the audio and stays retryable | `PipelineTests` |
| Remote audio arriving after commit is still written | `HardeningTests` |
| An unsupported call keeps recording for as long as it runs | `HardeningTests` |
| Only MeetTape's own relay, launched by a browser, may connect | `HardeningTests` |
| Every panel builds and lays out against a real view tree | `UITests` |
| Choosing a new storage folder takes effect without a relaunch | `UITests` |

## Exercised against real hardware and the real API

**Real capture chain.** `MEETTAPE_LIVE_CAPTURE=1 ./scripts/test.sh --filter LiveCapture`
runs the shipping `CaptureEngine` with `AVAudioEngine` and a CoreAudio process
tap for ten seconds. Verified: microphone audio recorded, segments rotated,
manifest closed with no open segments, every segment's frame count matching the
file on disk, and the pre-roll captured before commit flushed into the recording.

**A manual recording through the runtime.** The same command runs a second live
test that drives `MeetTapeRuntime` rather than the engine directly: it starts a
manual recording, captures for nine seconds, stops, and waits for the archive.
Verified: one meeting directory written under the configured storage root, source
`manual`, the manifest closed with no open segments, 9 s of microphone audio in
rotating segments whose frame counts match the files, the meeting duration
matching the capture, and processing reaching `audio_safe`. With no key in the
keychain it then fails at the first API call with a missing-credential error and
the recording is still intact, which is the guarantee that boundary exists for.

**The packaged app.** Built with `scripts/bundle-app.sh`, launched, and observed:
`menu bar item ready: true, visible: true` and `browser sensor server listening`
in the log, `lsappinfo` reporting `type="UIElement"` so there is no Dock
presence, and the native messaging host, its Firefox manifest and the sensor
socket all present in Application Support.

**A recording driven by a sensor event, end to end.** Before peer verification
existed, a simulated `in_call` event over the socket produced a real Google Meet
meeting: 65 seconds of microphone audio in three rotating 30-second CAF segments,
the Firefox tap correctly reporting `idle_but_bound` while Firefox was silent,
the meeting ID and URL from the event in `metadata.json`.

**Crash recovery on real files.** That recording was then killed with `pkill`.
On the next launch the app adopted the crash tail (5.1 s of the open segment),
reconstructed a segment the manifest had never recorded, reported a total of
65.1 s from per-segment accounting, and moved the meeting to `audio_safe`.

**The native messaging relay.** A host process connected to the app's socket,
relayed length-prefixed browser messages as newline-delimited JSON, and the app
logged connect and disconnect. After peer verification was added, the same test
is refused with "the relay was not launched by a browser", which is the intended
behaviour.

**A 32-minute capture soak.** `MEETTAPE_SOAK_MINUTES=30 ./scripts/test.sh --filter Soak`
ran the shipping `CaptureEngine` against real hardware for 1944 seconds:
65 segments written and closed, resident memory 29 MB at the start and 29 MB at
the end, zero engine restarts, and every segment's manifest frame count matching
the file on disk.

**Live OpenAI.** `MEETTAPE_LIVE_OPENAI=1` with a locally synthesised three-speaker
fixture. Six tests pass: credential and model access, transcription with segment
timings, diarization separating two remote speakers, the assembled transcript
keeping the microphone track as the local user and the remote track namespaced
per chunk, speaker resolution naming Chris and Tim from their self-introductions,
and enrichment producing a title and a summary.

**A full import through the real API.** `LiveEndToEnd` imports the fixture, runs
the whole pipeline, and checks the archive: processing reaches `complete`, the
transcript has several speakers and no local-user claim (an import has no
microphone track by construction), `transcript.md` and `summary.md` exist, the
original file is preserved byte for byte, and the human notes are untouched.

## Not verified

These are implemented but have not been exercised. Do not treat them as working.

- **A real Slack Huddle.** The `Leave Huddle` detection, its flap handling and
  the helper-process tap are covered by tests against recorded observations, but
  no huddle has been held against this build.
- **A real Google Meet or Zoom call in Firefox**, with the extension loaded from
  `extension/dist/firefox`. The sensor path was verified with a synthetic relay
  before peer verification landed; the browser-launched path has not been run.
- **Chrome.** The extension builds and its manifest parses, but MV3 service
  workers sleep, and no Chrome session has been observed. The Chrome native
  messaging manifest is not installed at all, because it needs the packed
  extension's ID.
- **A two-hour soak.** The longest continuous capture here was 32 minutes, with
  flat memory and no restarts. Nothing longer has been run.
- **Sleep, wake and lock during a recording.** The wake path has unit coverage
  through the coordinators' settle delay, but has not been exercised on hardware.
- **A Bluetooth device switch mid-recording.** The rebuild-storm mitigation is
  covered by tests reproducing the measured event sequence, not by reconnecting a
  headset against this build.
- **Notifications.** Under an ad-hoc signature macOS refuses to deliver them, so
  neither the notices nor the actionable "Keep recording?" buttons have been seen.
  This needs a Developer ID signature.
- **Gatekeeper, notarization and Homebrew.** No signing identity exists on this
  machine. See `docs/RELEASING.md`.
- **The appearance of the windows.** Onboarding, settings and review are built
  and laid out in `UITests` through `NSHostingController`, which catches a view
  that traps but says nothing about how any of it looks. No screenshot pass or
  human walkthrough of the panels has been done.
- **FaceTime.** Not implemented as a provider; a FaceTime call would be detected,
  if at all, through the generic path.

## Long-meeting processing

**Run and passed.** `MEETTAPE_LIVE_LONG=1` put a 65-minute recording through the
chunked pipeline against the live API, taking 30 minutes. Verified: the recording
chunked, no chunk exceeded the model's 1400-second duration limit, raw speaker
labels stayed distinct per chunk, canonical timestamps stayed monotonic across
chunk boundaries, the transcript spanned the recording, and the deliberate
overlap between chunks produced no duplicated utterances.

It costs real money and takes tens of minutes, so it is not part of an ordinary
run.
