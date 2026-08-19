# MeetTape

MeetTape is a macOS menu-bar application that records meetings without being
asked. It watches for Slack Huddles and for Google Meet and Zoom in the browser,
captures the microphone and the meeting audio as two separate streams, transcribes
and diarizes them through OpenAI, and leaves ordinary files behind.

It never joins a meeting as a participant, needs no calendar entry, records no
video, and stores nothing in a proprietary database.

The design goal is narrow: **never miss the beginning of a meeting.** A slightly
overlong recording is acceptable. A missing first sentence is not.

## What works today

| Workflow | State |
|---|---|
| Slack Huddle, automatic | Joins detected from the `Leave Huddle` accessibility control |
| Google Meet in Firefox, automatic | Extension when installed, window title and microphone state otherwise |
| Zoom in Firefox, automatic | Same path; the numeric meeting ID needs the extension |
| Unsupported applications | Provisional recording, then "keep this?" |
| Manual recording | Menu bar, unaffected by provider state |
| In-person meeting | Microphone only, diarized |
| Import a recording | WAV, M4A, MP3, CAF, AIFF, MP4 via AVFoundation |
| Transcription and diarization | OpenAI, chunked for long meetings |
| Speaker names | Suggested by the model, always correctable by hand |
| Crash recovery | Interrupted recordings are adopted, not discarded |

FaceTime detection and Safari are not implemented. Chrome ships the same
extension but its MV3 service worker sleeps, so the sensor is less reliable there
than in Firefox; native detection covers it either way.

## How capture works

Two independent sources share one host clock:

```
microphone ── AVAudioEngine ──┐
                              ├── 30 s CAF segments + fsync'd manifest
meeting app ── CoreAudio tap ─┘
```

Neither stream is mixed at record time and neither is resampled. Alignment
happens later from the host timestamps stamped on every buffer.

The details below are not stylistic preferences. Each one comes from a measured
failure:

- **A configuration-change burst is debounced for 400 ms before rebuilding.**
  macOS emits several topology events while Bluetooth negotiates, and one of them
  described a device mid-teardown as 0 channels at 0 Hz.
- **The frame watchdog is suppressed for 1.5 s after a rebuild starts.** Without
  it the watchdog and the configuration observer drove each other into eight
  rebuilds in 5.8 seconds.
- **The microphone watchdog measures buffer arrival, not amplitude, at 2 s.**
  An `AVAudioEngine` can report `isRunning == true` while its callbacks have been
  dead for minutes. Silence is normal; absence of callbacks is not.
- **The remote tap uses a different health model entirely.** A tap on an idle
  application delivers no callbacks at all, forever, and that is correct. Only
  "the app is producing output and we are receiving nothing" is a fault.
- **Duration is summed per segment.** A Bluetooth profile switch drops the input
  to 16 kHz mid-meeting; dividing accumulated frames by the current rate
  under-reported a real session by two thirds.
- **Segments are CAF.** Under `SIGKILL`, CAF stayed fully readable, WAV
  under-reported its tail, and M4A became unopenable.

## Architecture

```
MeetTapeCore          pure logic: manifest, timeline, recovery policy, session
                      lifecycle, chunk planning, transcript assembly, storage
MeetTapeAudio         AVAudioEngine, CoreAudio process taps, segment writing,
                      pre-roll, import, mixdown
MeetTapeDetection     accessibility, window titles, audio process observation,
                      the browser sensor socket
MeetTapeIntegrations  OpenAI, Keychain, EventKit, notifications, permissions
MeetTapeServices      runtime wiring and the processing pipeline
MeetTapeUI            menu bar, onboarding, settings, meeting review
```

Detection produces evidence. `SessionController` decides the lifecycle.
`CaptureEngine` captures. No provider adapter owns a recording, and the browser
extension is a sensor that can disappear without stopping anything.

Capture is a two-stage promotion: it starts the moment a call becomes a
*candidate*, writing into a 15-second memory ring, and only becomes files when
the call is *confirmed*. An abandoned prejoin screen therefore leaves nothing
behind, and a confirmed meeting still has its opening sentence.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Developer setup

Requirements: macOS 15 or later and a Swift 6 toolchain. Xcode is not required;
the project builds with Command Line Tools.

```bash
git clone https://github.com/Neeeser/MeetTape.git
cd MeetTape
./scripts/build.sh          # debug build
./scripts/test.sh           # the whole suite
./scripts/bundle-app.sh     # assembles dist/MeetTape.app, ad-hoc signed
open dist/MeetTape.app
```

Tests run as a plain executable (`meettape-test`) rather than through `swift
test`, because XCTest and swift-testing ship with Xcode and this project is built
to work without it.

```bash
./scripts/test.sh --list                    # every test name
./scripts/test.sh --filter SlackHuddle      # one suite
```

Ad-hoc signing means macOS re-issues every TCC grant on each rebuild. Expect to
re-grant Microphone, Accessibility and Screen Recording after `bundle-app.sh`.
A Developer ID signature has a stable designated requirement and does not have
this problem.

## Browser extension

```bash
cd extension
npm test          # the sensor logic
./build.sh        # writes dist/firefox and dist/chrome
```

To load it in Firefox during development: `about:debugging#/runtime/this-firefox`
→ Load Temporary Add-on → pick `extension/dist/firefox/manifest.json`. Content
scripts do not appear in tabs that were already open, so reload any Meet or Zoom
tab afterwards.

The extension talks to a compiled native messaging host, not to a script: browsers
spawn hosts with a minimal `PATH`, so an interpreter shebang silently never
resolves. MeetTape installs the host and its manifest on launch.

The app only accepts a socket connection from its own relay binary, launched by a
browser. MeetTape holds the microphone grant, so anything that could fake a
meeting event would get recording without a prompt of its own. A refused
connection is logged with its reason and shown in Settings → Permissions.

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | Recording your side | Nothing can be recorded |
| System Audio & Screen Recording | Window titles for detection | Browser detection falls back to audio state |
| Accessibility | Slack Huddle join and leave | Slack falls back to microphone heuristics |
| Calendar | Titles and attendees | Everything still records |
| Notifications | Start, saved and failure messages | Silent operation |

Process taps need no prompt of their own beyond Microphone. Settings shows the
effective state of each permission rather than trusting the System Settings
toggle, because a stale TCC record can read as enabled while the running build
has no access.

## OpenAI configuration

Settings → OpenAI takes an API key, stores it in the login keychain, and offers
Test Connection, which fetches one model description at no cost and proves both
the key and access to that model.

Models are configuration, not constants:

- transcription defaults to `whisper-1`, which returns the timings the timeline
  needs; several newer models return excellent text with no segments at all;
- diarization defaults to `gpt-4o-transcribe-diarize`;
- metadata defaults to `gpt-5.1`.

Every enrichment is optional. With all of them off, MeetTape still records and
still transcribes.

Spend and usage are not readable from a project key, so MeetTape shows no balance
and links to the OpenAI dashboard instead.

## Where recordings live

`~/Documents/MeetTape/Meetings/YYYY/MM/<meeting>/`, configurable in Settings.

```
2026-08-18-1418-slack-huddle-engineering/
├── segments/
│   ├── mic.0001.caf          immutable source
│   ├── system.0001.caf       immutable source
│   └── manifest.jsonl        append-only, the timeline authority
├── api/                      raw API responses, exactly as received
├── metadata.json             title, participants, calendar link, processing state
├── transcript.raw.json       raw diarization, never rewritten
├── speakers.map.json         label to name, human-editable
├── transcript.json           canonical timeline
├── transcript.md             rendered for reading
├── notes.md                  yours, never touched by AI
├── summary.md                generated
└── mixed.caf                 derived, safe to delete
```

Renaming a speaker edits `speakers.map.json` and re-renders. It never
re-transcribes and never modifies the raw diarization.

## Privacy

Audio goes to OpenAI, because cloud transcription is what the product does. It
goes nowhere else. There is no MeetTape account, no telemetry, and no analytics.

Logs carry operational facts only: identifiers, counts, durations, health states.
Meeting titles, transcripts, notes, participant names and meeting URLs are never
logged, and the API key is never written to disk outside the keychain.

Uninstalling MeetTape leaves every recording readable.

## What has been verified

[docs/VERIFICATION.md](docs/VERIFICATION.md) records what was actually exercised
and what was only implemented, including a real capture run against hardware, a
crash recovered from real files, and a full import through the live API. Several
things are implemented but unverified, including a real Slack Huddle, a real
browser meeting with the extension loaded, and a long soak. They are listed there
rather than implied here.

## Licence

MIT. See [LICENSE](LICENSE).
