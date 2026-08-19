# MeetTape

MeetTape is a macOS menu-bar application that records meetings automatically. It
detects Slack Huddles and Google Meet and Zoom calls in the browser, records the
microphone and the meeting audio as two separate streams, transcribes and
diarizes them through the OpenAI API, and writes the results to ordinary files on
disk.

It does not join meetings as a participant, does not require a calendar entry,
does not record video, and does not store anything in a proprietary database.

The main design requirement is that a recording covers the start of the meeting.
Capture begins as soon as a call looks likely and the first fifteen seconds are
held in memory, so the opening of a meeting is included once the call is
confirmed.

## Supported workflows

| Workflow | Implementation |
|---|---|
| Slack Huddle, automatic | Detected from the `Leave Huddle` accessibility control |
| Google Meet in Firefox, automatic | Browser extension when installed, otherwise window titles and microphone state |
| Zoom in Firefox, automatic | Same path; the numeric meeting ID requires the extension |
| Unsupported applications | Records provisionally and asks whether to keep the recording |
| Manual recording | Started from the menu bar and unaffected by provider state |
| In-person meeting | Microphone only, diarized |
| Import a recording | WAV, M4A, MP3, CAF, AIFF and MP4 through AVFoundation |
| Transcription and diarization | OpenAI, chunked for long meetings |
| Speaker names | Suggested by the model and editable by hand |
| Crash recovery | Interrupted recordings are adopted on the next launch |

FaceTime detection and Safari support are not implemented. The extension builds
for Chrome, but its native messaging manifest is not installed, because that
requires the ID of a packed extension, so the sensor does not run on Chrome at
all today. Chrome meetings are detected through window titles and microphone
state, the same path Firefox uses without the extension.

## How capture works

Two independent sources share one host clock:

```
microphone ── AVAudioEngine ──┐
                              ├── 30 s CAF segments + fsync'd manifest
meeting app ── CoreAudio tap ─┘
```

The streams are neither mixed nor resampled while recording. Alignment is
computed afterwards from the host timestamps recorded with every buffer.

The following details come from measurements taken during development, and each
one addresses a failure that was observed on real hardware:

- Configuration changes are debounced for 400 ms before the engine is rebuilt.
  macOS emits several device topology events while Bluetooth negotiates, and one
  of them described a device that was mid-teardown as 0 channels at 0 Hz.
- The frame watchdog is suppressed for 1.5 s after a rebuild starts. Without the
  delay, the watchdog and the configuration observer triggered each other and
  produced eight rebuilds in 5.8 seconds.
- The microphone watchdog measures buffer arrival at a 2-second threshold rather
  than signal amplitude. An `AVAudioEngine` can report `isRunning == true` while
  its callbacks have been dead for minutes, and a silent room is normal.
- The remote tap uses a separate health model. A tap on an application that is
  producing no audio delivers no callbacks at all, which is the expected
  behaviour, so the fault condition is the application producing output while the
  tap receives nothing.
- Duration is summed per segment. A Bluetooth profile switch drops the input to
  16 kHz mid-meeting, and dividing an accumulated frame count by the current
  sample rate under-reported a real session by two thirds.
- Segments are written as CAF. After `SIGKILL`, CAF files remained fully
  readable, WAV files under-reported their tail, and M4A files could not be
  opened.
- The microphone runs through the system voice-processing unit by default,
  which subtracts what the speakers are playing. A call taken without
  headphones otherwise records the remote side onto the local track, where it
  is transcribed under the local user's name. Ducking is disabled so the
  meeting audio being recorded is not attenuated, and capture falls back to
  the plain input when the unit refuses the device pairing.

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

Detection code produces evidence about what is happening on the machine.
`SessionController` consumes that evidence and owns the recording lifecycle, and
`CaptureEngine` performs the capture. Provider adapters have no control over
recordings, and the browser extension is one evidence source among several, so
losing it reduces detection accuracy without stopping a recording.

Capture uses a two-stage promotion. It starts as soon as a call becomes a
candidate and writes into a 15-second ring buffer in memory. Files are created
only when the call is confirmed, so an abandoned prejoin screen leaves nothing on
disk while a confirmed meeting still includes its opening.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

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

Tests run as a plain executable (`meettape-test`) instead of through `swift
test`, because XCTest and swift-testing ship with Xcode and this project is built
to work without it.

```bash
./scripts/test.sh --list                    # every test name
./scripts/test.sh --filter SlackHuddle      # one suite
```

Ad-hoc signing means macOS reissues every TCC grant on each rebuild, so
Microphone, Accessibility and Screen Recording have to be granted again after
running `bundle-app.sh`. A Developer ID signature has a stable designated
requirement and keeps its grants across rebuilds.

## Browser extension

```bash
cd extension
npm test          # the sensor logic
./build.sh        # writes dist/firefox and dist/chrome
```

To load the extension in Firefox during development, open
`about:debugging#/runtime/this-firefox`, choose Load Temporary Add-on, and select
`extension/dist/firefox/manifest.json`. Content scripts are not injected into
tabs that were already open, so reload any Meet or Zoom tab afterwards.

The extension communicates with a compiled native messaging host. Browsers spawn
hosts with a minimal `PATH`, so a script with an interpreter shebang fails to
launch. MeetTape installs the host binary and its manifest at startup.

The application accepts a socket connection only from its own relay binary when
that binary was launched by a browser. MeetTape holds the microphone grant, so a
process able to send a fabricated meeting event could record audio without
triggering a permission prompt of its own. Refused connections are logged with a
reason and shown in Settings under Permissions.

## Permissions

| Permission | Used for | Effect when missing |
|---|---|---|
| Microphone | Recording the local participant | No recording is possible |
| System Audio and Screen Recording | Window titles used in detection | Browser detection falls back to audio state |
| Accessibility | Slack Huddle join and leave detection | Slack detection falls back to microphone heuristics |
| Calendar | Meeting titles and attendees | Recording is unaffected |
| Notifications | Start, saved and failure messages | The application runs silently |

Process taps require no prompt beyond the microphone grant. The Permissions tab
in Settings reports the effective state of each permission by probing it, because
a stale TCC record can appear enabled in System Settings while the running build
has no access.

## OpenAI configuration

The OpenAI tab in Settings accepts an API key, stores it in the login keychain,
and provides a Test Connection button that fetches a single model description to
confirm both the key and access to that model.

Model identifiers are settings rather than constants:

- transcription defaults to `whisper-1`, which returns the segment timings the
  timeline needs, while several newer models return good text with no timings;
- diarization defaults to `gpt-4o-transcribe-diarize`;
- metadata defaults to `gpt-5.6-luna`, selectable from a dropdown or entered by
  hand. Metadata requests run at low reasoning effort, because titles, summaries
  and speaker mapping are extraction rather than problem solving.

Every enrichment step is optional. With all of them disabled, MeetTape still
records and transcribes.

Spend and usage are not readable through a project key, so MeetTape shows no
balance and links to the OpenAI dashboard.

## Where recordings are stored

Recordings are written to `~/Documents/MeetTape/Meetings/YYYY/MM/<meeting>/`,
which can be changed in Settings.

```
2026-08-18-1418-slack-huddle-engineering/
├── segments/
│   ├── mic.0001.caf          source audio for the local microphone
│   ├── system.0001.caf       source audio for the meeting application
│   └── manifest.jsonl        append-only record of every capture event
├── api/                      API responses as received
├── metadata.json             title, participants, calendar link, processing state
├── transcript.raw.json       diarization output as returned by the model
├── speakers.map.json         mapping from raw labels to names, editable by hand
├── transcript.json           canonical transcript on a single timeline
├── transcript.md             rendered transcript for reading
├── notes.md                  user notes, which no processing step modifies
├── summary.md                generated summary
└── mixed.caf                 mixdown of both tracks, regenerated on demand
```

The manifest is the authoritative timeline; audio container headers are not
trusted. The source segments, the manifest lines, the raw API responses and any
imported original file are never modified after they are written. The Markdown
files, `summary.md` and `mixed.caf` are derived from those inputs and can be
deleted safely.

Renaming a speaker updates `speakers.map.json` and re-renders the transcript. It
does not re-transcribe the audio and does not modify the raw diarization output.

## Privacy

Audio is uploaded to the OpenAI API for transcription and diarization, which is
how the transcripts are produced. It is not sent anywhere else. There is no
MeetTape account, no telemetry and no analytics.

Logs contain operational information only: identifiers, counts, durations and
health states. Meeting titles, transcripts, notes, participant names and meeting
URLs are treated as content and are never logged. The API key is stored in the
keychain and is not written anywhere else on disk.

Recordings remain readable after MeetTape is uninstalled.

## Verification status

[docs/VERIFICATION.md](docs/VERIFICATION.md) records which behaviour has been
exercised and which has only been implemented, including a capture run against
real hardware, recovery from a crash on real files, and a full import through the
live API. Several features are implemented but unverified, among them a real
Slack Huddle, a real browser meeting with the extension loaded, and a long soak.
They are listed in that file.

## Licence

MIT. See [LICENSE](LICENSE).
