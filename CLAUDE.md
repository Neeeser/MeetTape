# MeetTape — working notes

Stable repository knowledge for anyone (human or agent) picking this up. Product
behaviour lives in the README; this file is about how to work in the tree.

## Build and test

```bash
./scripts/build.sh [debug|release]   # canonical build
./scripts/test.sh [--filter X]       # canonical test run
./scripts/bundle-app.sh [debug|release]   # assembles dist/MeetTape.app
cd extension && npm test             # browser sensor logic
```

Three environment facts shape all of the above, and none of them are choices:

- **There is no Xcode on the development machine**, only Command Line Tools, so
  there is no `xcodebuild` and no `.xcodeproj`. The app bundle is assembled by
  `scripts/bundle-app.sh`.
- **XCTest and swift-testing ship with Xcode**, so the suite runs as an ordinary
  executable through `Sources/TestKit`. `swift test` does not work here.
- **SwiftUI's `@State` and `@Binding` are macros** whose plugin also ships with
  Xcode. View state therefore lives in `@Observable` model classes that
  `WindowManager` owns, and bindings are built with `Binding(get:set:)`. The
  Observation macro *is* available, so views still update automatically. Do not
  reintroduce `@State`.

`scripts/spm-env.sh` repairs a stale `PackageDescription.private.swiftinterface`
in some Command Line Tools installs; without it every manifest fails to link. It
is a no-op on a healthy toolchain and is sourced by the other scripts.

## Capture invariants

These came from measurement, and changing any of them changes behaviour that was
verified against real hardware. `CaptureThresholds` holds the numbers.

| Rule | Why |
|---|---|
| Debounce configuration changes 400 ms before rebuilding | Bluetooth emits bursts, one of which reported 0 channels at 0 Hz mid-teardown |
| Suppress the watchdog 1.5 s after a rebuild starts | Otherwise the watchdog and the config observer produce a rebuild storm: 8 rebuilds in 5.8 s |
| Microphone watchdog on buffer arrival at 2 s | `engine.isRunning` stayed true with dead callbacks for minutes |
| Never adopt an unusable device format | Keep the last good format instead of rebuilding against 0ch/0Hz |
| Remote health uses `kAudioProcessPropertyIsRunningOutput`, 5 s fault threshold | A tap on an idle app delivers no callbacks at all; that is normal, not a fault |
| Resolve tap targets by bundle-ID prefix on every poll | Slack Huddle audio lives in `com.tinyspeck.slackmacgap.helper`, and Firefox restarts under a new PID |
| Duration is `sum(frames / rate)` per segment | A Bluetooth switch to 16 kHz made the naive formula under-report by two thirds |
| Segments are CAF, rotated at 30 s | CAF survives `SIGKILL` intact; WAV under-reports its tail and M4A becomes unopenable |
| Capture starts at candidate into a memory ring | Slack opens the mic 12.2 s before the user joins; Meet prejoin is invisible natively |
| One missing `Leave Huddle` read never ends a huddle | Slack's accessibility subtree reads empty intermittently during a live call |
| The browser extension can vanish without stopping a recording | Detection falls back to native signals; a DOM regression should cost precision, not the meeting |
| Sensor evidence is combined with native evidence, never substituted for it | A provider renaming its leave button would otherwise take a live meeting from confirmed to nothing |
| Detection keeps asserting a meeting every poll, not once at its start | The session ends a recording whose evidence disappears, so a one-shot event cuts the call short |
| Only MeetTape's own relay, launched by a browser, may use the sensor socket | The app holds the microphone grant, so a faked meeting event is recording without a prompt |
| Content scripts are plain scripts, never ES modules | An `import` statement makes the whole script fail to load and the sensor silently never runs |
| No file I/O, manifest write or device work on an audio callback | An fsync on a render thread drops the audio it was recording |
| Every device build, teardown and poll runs on the capture control queue | Otherwise a poll-driven rebuild races a user-driven stop and leaves a live engine running |

Regression tests for all of these live in `Sources/MeetTapeTests/CaptureRecoveryTests.swift`,
`DetectionTests.swift`, `ManifestTests.swift` and `HardeningTests.swift`. If one
of them starts failing, the behaviour regressed; the test is not wrong.
`docs/VERIFICATION.md` records what has been run against real hardware and what
has not.

## Architectural boundaries

- `MeetTapeCore` is Foundation-only and holds every decision that can be made
  without I/O: recovery policy, session lifecycle, chunk planning, transcript
  assembly, manifest and storage layout. New logic belongs here by default.
- Provider adapters **emit evidence**. They never start, stop or own a recording.
  `SessionController` is the only thing that decides lifecycle.
- The coordinators (`MicrophoneRecoveryCoordinator`, `RemoteTapCoordinator`) hold
  the algorithm; `MeetTapeAudio` supplies AVFoundation and CoreAudio behind
  `MicrophoneEngineController` and `ProcessTapController`. Tests drive the real
  algorithm through fakes rather than re-implementing it.
- Ground truth is immutable: source CAF segments, manifest lines, raw API
  responses and imported originals are never rewritten. Titles, notes, the
  speaker map and metadata are mutable. Markdown, `mixed.caf` and summaries are
  derived and safe to delete.
- Nothing before `audio_safe` touches OpenAI. Every stage after it is retryable
  and must never delete source audio.

## Secrets

- The OpenAI key lives in the login keychain and nowhere else: not in
  preferences, meeting files, logs, fixtures, tests or CI.
- CI fails the build on anything shaped like a key in the tree, and on any
  committed audio file.
- `plans/` and `probes/` are local investigation material. They are gitignored
  and must stay untracked.

## Logging

`Log` in `MeetTapeCore` exposes one logger per subsystem. Operational facts only:
identifiers, counts, durations, health states, error categories. Meeting titles,
transcripts, notes, participant names and meeting URLs are content and never go
to the log. Errors are described through `logSafeDescription`.

## Live API tests

They are skipped unless explicitly enabled, so an ordinary run costs nothing:

```bash
./scripts/make-live-fixture.sh /tmp/meettape-fixture   # local `say`, free
MEETTAPE_LIVE_OPENAI=1 \
MEETTAPE_LIVE_FIXTURE=/tmp/meettape-fixture \
OPENAI_API_KEY=<your key> \
  ./scripts/test.sh --filter LiveOpenAI
```

The fixture is synthesised locally, so only the requests are live. Assertions
count how many expected terms survive transcription rather than demanding an
exact word, because synthetic speech transcribes with variation.

Two further opt-in suites: `MEETTAPE_LIVE_CAPTURE=1` records ten seconds from the
real microphone and process tap and checks the manifest against the files on
disk, and `MEETTAPE_LIVE_LONG=1` puts an hour of audio through the chunked
pipeline. The second one costs money and takes tens of minutes.

## Release

`docs/RELEASING.md` has the full procedure. In short: tag `vX.Y.Z`, and
`.github/workflows/release.yml` builds, tests, packages and drafts a release.
Signing and notarization activate when the Apple secrets exist and are skipped
with a warning when they do not. Do not publish an unsigned build as a release.
