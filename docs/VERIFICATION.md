# Verification

Verified behavior has been run and checked. An implementation alone does not
count as verification.

The latest hardware checks used a MacBook Pro with an M2 Pro. The machine ran
macOS 27 with Command Line Tools and no Developer ID signing identity.

## Automated checks

Run the application and browser sensor suites with:

```sh
./scripts/test.sh
(cd extension && npm test)
```

The application suite covers these areas:

| Area | Coverage |
| --- | --- |
| Capture | Device recovery, segment writing, mixed sample rates, and process taps |
| Detection | Slack, browser calls, provider changes, stale evidence, and fallback paths |
| Storage | Manifest recovery, immutable artifacts, archive compaction, and reconnects |
| Processing | Backend selection, chunking, alignment, assembly, retry, and resume |
| Speakers | Attribution, corrections, identity matching, merges, and voice evidence |
| Interface | Settings, meeting review, file selection, and model pickers |
| Benchmarks | Ground-truth parsing, scorer behavior, suite policy, and baseline gates |

The extension suite covers event ordering, stale tab state, provider detection,
and manifest generation.

GitHub Actions runs both suites on every pull request and push to `main`. CI also
builds debug and release configurations, assembles the application bundle,
verifies its signature and resources, and scans the repository for keys and
audio files.

## Opt-in checks

These commands use hardware, downloaded models, network services, or long audio.
They do not run in the ordinary suite.

| Check | Command |
| --- | --- |
| Prevent model downloads during tests | `./scripts/check-offline.sh` |
| Capture through real audio devices | `PIPIT_LIVE_CAPTURE=1 ./scripts/test.sh --filter LiveCapture` |
| Run on-device speech models | `PIPIT_LOCAL_MODELS=1 PIPIT_LIVE_FIXTURE=/tmp/pipit-fixture ./scripts/test.sh --filter LocalModels` |
| Call OpenAI speech endpoints | `PIPIT_LIVE_OPENAI=1 PIPIT_LIVE_FIXTURE=/tmp/pipit-fixture OPENAI_API_KEY=... ./scripts/test.sh --filter LiveOpenAI` |
| Process a long recording | `PIPIT_LIVE_LONG=1 PIPIT_LIVE_FIXTURE=/tmp/pipit-fixture ./scripts/test.sh` |
| Run a capture soak | `PIPIT_SOAK_MINUTES=30 ./scripts/test.sh --filter Soak` |

Create the local fixture with:

```sh
./scripts/make-live-fixture.sh /tmp/pipit-fixture
```

Benchmark commands and their data requirements are documented in
[Benchmarks](../Benchmarks/README.md).

## Observed on hardware

The following paths have been exercised outside unit tests:

- The shipping capture engine recorded microphone and process audio, rotated
  segments, closed its manifest, and read the result through the storage layer.
- A 32-minute capture wrote 65 closed segments with flat resident memory and no
  engine restarts.
- Pipit recovered a killed recording from its manifest and open segment, then
  advanced it to `audio_safe`.
- Firefox Google Meet detection reached candidate and confirmed states through
  native window and microphone evidence.
- The Firefox sensor held a Google Meet prejoin screen as a candidate without
  creating a meeting.
- A real Slack Huddle was detected, recorded, and ended through the audio-only
  path while Accessibility and Screen Recording were denied.
- A packaged application launched as a menu-bar-only process and installed its
  native messaging host and browser resources.
- Local transcription and diarization completed with network access denied
  after their models were installed.
- OpenAI transcription, diarization, enrichment, and long-recording chunking
  completed against live endpoints.
- Speaker corrections, re-analysis, and recurring identity updates were driven
  through the installed application interface.

## Remaining manual checks

These paths still need direct observation:

- A two-hour continuous capture
- Zoom detection and recording
- Chrome sensor delivery through a packed extension
- A full Google Meet join, refresh, leave, and reconnect through the sensor
- Sleep, wake, screen lock, and Bluetooth device changes during capture
- Other applications' playback level is unchanged from the moment recording starts
- On a multichannel input device, the microphone track holds the capsule: the mono
  downmix takes channel 0, and a device that puts the microphone elsewhere would
  record a silent track beside a live energy profile
- A signed and notarized build installed on a clean Mac
- Installation and removal through the published Homebrew cask
- Calendar matching against a real calendar
- Voice recognition across real meetings recorded weeks apart
- A dropped and rejoined call stored as one logical meeting on hardware
- A visual walkthrough of onboarding, settings, and meeting review

Update this file when a manual check is observed. Record the path and result.
Keep raw transcripts, recordings, credentials, and participant names out of the
repository.
