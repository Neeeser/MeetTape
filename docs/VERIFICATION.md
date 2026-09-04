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

- Screen & System Audio Recording missing, Microphone granted: remove Pipit
  from that list in System Settings, start a call, and confirm the menu bar
  icon turns red with a mark, a floating "Pipit can't record the other
  people in this meeting" panel appears in front of the call on the screen
  the pointer is on, the panel carries the System Settings picture with
  Pipit draggable from it and an Open System Settings button, a "Recording
  problem" notification arrives, the meeting's header shows the warning
  after it ends, and `metadata.json` carries
  `system_audio_permission_missing`. With the panel dismissed and the call
  still running, it returns after a minute. Switching Pipit on in the pane
  closes the panel and clears the red icon on its own.
- Microphone missing only: remove Pipit from the Microphone list, press
  Start In-Person Meeting twice within a minute, and confirm no meeting
  folder is created, the "Pipit can't record this meeting" panel appears in
  front both times with an Allow Microphone button, allowing it in the macOS
  prompt starts the recording without a second press, and the icon is plain
  again.
- Both missing: press Start Recording and confirm the panel offers Open
  Setup instead, and that Setup opens on the Microphone step with red marks
  on Microphone and Screen recording.
- Setup placement: with a second display attached, put the pointer on one
  screen and open Setup from the menu; it appears centred on that screen, in
  front. Close it, put another application in full screen, reopen Setup from
  the menu, and confirm it comes up in front of the full-screen application.
- Setup marks: continue past Calendar and alerts with both off and past
  Firefox without installing the add-on, quit and relaunch, and confirm both
  show a blue check. Turn calendar and notifications on and confirm the row
  turns green. A required step never done shows a red X on every launch,
  including after an unsigned reinstall dropped the grant.
- Local signing identity: run `scripts/make-signing-identity.sh`, rebuild and
  reinstall twice, and confirm Microphone, Accessibility and Screen & System
  Audio Recording stay granted across the second install.

These paths still need direct observation:

- A two-hour continuous capture
- Zoom detection and recording
- Chrome sensor delivery through a packed extension
- A full Google Meet join, refresh, leave, and reconnect through the sensor
- Sleep, wake, screen lock, and Bluetooth device changes during capture
- Other applications' playback level is unchanged from the moment recording starts
- A call taken on speakers: `raw/audio/mic.cleaned.m4a` holds the local user and
  not the far end, `raw/audio/mic.m4a` still holds both, and the transcript
  carries the far end's words on the remote track only. The same call taken on
  headphones writes no cleaned file at all
- The local user's voice profile is enrolled from the cleaned microphone rather
  than from the recording, and it is matched in every other meeting against
  embeddings taken from raw tracks. The cost of that domain shift is unmeasured.
  The nearest figure there is comes from enrolling on call audio and testing on
  room audio, which cost 0.01 to 0.03 of similarity
- On an input device with more than two channels, the mono downmix keeps the
  channel carrying the most energy over the first 30 seconds. The scan runs only
  above two channels, so a mono or stereo device is mixed down the way it always
  was. A device whose microphone is not its loudest channel would record the
  wrong one
- A signed and notarized build installed on a clean Mac
- Installation and removal through the published Homebrew cask
- Calendar matching against a real calendar
- Voice recognition across real meetings recorded weeks apart
- A dropped and rejoined call stored as one logical meeting on hardware
- A visual walkthrough of onboarding, settings, and meeting review

Update this file when a manual check is observed. Record the path and result.
Keep raw transcripts, recordings, credentials, and participant names out of the
repository.
