# MeetTape development notes

Reference material for anyone working in this repository. Product behaviour is
documented in the README; this file covers how to build, test and change the
code.

## Build and test

```bash
./scripts/build.sh [debug|release]   # canonical build
./scripts/test.sh [--filter X]       # canonical test run
./scripts/bundle-app.sh [debug|release]   # assembles dist/MeetTape.app
cd extension && npm test             # browser sensor logic
```

Three properties of the development environment determine how the project is set
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

`scripts/spm-env.sh` repairs a stale `PackageDescription.private.swiftinterface`
found in some Command Line Tools installs, without which every manifest fails to
link. It does nothing on a healthy toolchain and is sourced by the other scripts.

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
| Only MeetTape's own relay, launched by a browser, may use the sensor socket | The application holds the microphone grant, so a fabricated meeting event would produce a recording without a prompt |
| Content scripts are plain scripts and never ES modules | An `import` statement makes the whole script fail to load and the sensor silently never runs |
| No file I/O, manifest write or device work on an audio callback | An `fsync` on a render thread drops the audio being recorded |
| Every device build, teardown and poll runs on the capture control queue | Otherwise a poll-driven rebuild races a user-driven stop and leaves a live engine running |

Regression tests for these rules are in
`Sources/MeetTapeTests/CaptureRecoveryTests.swift`, `DetectionTests.swift`,
`ManifestTests.swift` and `HardeningTests.swift`. A failure in one of them
indicates a behavioural regression. `docs/VERIFICATION.md` records what has been
run against real hardware and what has not.

## Architectural boundaries

- `MeetTapeCore` imports only Foundation and holds every decision that can be
  made without I/O: recovery policy, session lifecycle, chunk planning,
  transcript assembly, manifest handling and storage layout. New logic belongs
  here by default.
- Provider adapters emit evidence. They do not start, stop or own recordings.
  `SessionController` is the only component that decides lifecycle.
- The coordinators (`MicrophoneRecoveryCoordinator`, `RemoteTapCoordinator`) hold
  the recovery algorithms, and `MeetTapeAudio` supplies AVFoundation and
  CoreAudio implementations behind `MicrophoneEngineController` and
  `ProcessTapController`. Tests drive the real algorithm through fakes instead of
  reimplementing it.
- Source CAF segments, manifest lines, raw API responses and imported originals
  are immutable once written. Titles, notes, the speaker map and metadata are
  mutable. Markdown files, `mixed.caf` and summaries are derived and can be
  regenerated.
- Nothing before `audio_safe` sends data to OpenAI. Every stage after it is
  retryable and must never delete source audio.

## Secrets

- The OpenAI key is stored in the login keychain only: not in preferences,
  meeting files, logs, fixtures, tests or CI.
- CI fails the build on anything shaped like an API key in the tree, and on any
  committed audio file.
- `plans/` and `probes/` hold local investigation material. They are gitignored
  and must stay untracked.

## Logging

`Log` in `MeetTapeCore` exposes one logger per subsystem. Log lines carry
operational information only: identifiers, counts, durations, health states and
error categories. Meeting titles, transcripts, notes, participant names and
meeting URLs are content and are never logged. Errors are formatted through
`logSafeDescription`.

## Live API tests

Live tests are skipped unless explicitly enabled, so an ordinary run makes no API
calls:

```bash
./scripts/make-live-fixture.sh /tmp/meettape-fixture   # local `say`, free
MEETTAPE_LIVE_OPENAI=1 \
MEETTAPE_LIVE_FIXTURE=/tmp/meettape-fixture \
OPENAI_API_KEY=<your key> \
  ./scripts/test.sh --filter LiveOpenAI
```

The fixture is synthesised locally, so only the API requests are live.
Assertions count how many expected terms survive transcription instead of
requiring exact wording, because synthetic speech transcribes with variation.

Two further opt-in suites exist. `MEETTAPE_LIVE_CAPTURE=1` records from the real
microphone and process tap, checks the manifest against the files on disk, and
runs a manual recording through `MeetTapeRuntime`. `MEETTAPE_LIVE_LONG=1` puts an
hour of audio through the chunked pipeline; it costs money and takes tens of
minutes.

## Release

`docs/RELEASING.md` documents the full procedure. In summary: tag `vX.Y.Z`, and
`.github/workflows/release.yml` builds, tests, packages and drafts a GitHub
release. Signing and notarization run when the Apple secrets are configured and
are skipped with a warning when they are absent. Do not publish an unsigned build
as a release.
