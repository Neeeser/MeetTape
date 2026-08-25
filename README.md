# MeetTape

MeetTape is a macOS menu-bar application that records meetings automatically. It
detects Slack Huddles and Google Meet and Zoom calls in the browser, records the
microphone and the meeting audio as two separate streams, transcribes them and
works out who spoke when on this Mac, and writes the results to ordinary files on
disk.

Transcription and speaker identification run on device by default and need no API
key. MeetTape also remembers voices: a person you name once is recognized in
later meetings, and a voice that recurs without a name is remembered as one until
you name it. Voice profiles never leave the machine.

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
| Transcription | Parakeet, Cohere Transcribe or Whisper on device, or OpenAI |
| Speaker separation | FluidAudio on device, or OpenAI |
| Speaker recognition | Local voice profiles, named people and recurring unnamed voices |
| Speaker names | Editable per speaker and per transcript line |
| Crash recovery | Interrupted recordings are adopted on the next launch |

FaceTime detection and Safari support are not implemented. The extension builds
for Chrome, but its native messaging manifest is not installed, because that
requires the ID of a packed extension, so the sensor does not run on Chrome at
all today. Chrome meetings are detected through window titles and microphone
state, the same path Firefox uses without the extension.

## Processing

```
meeting ends
      ↓
transcription        Apple SpeechAnalyzer or Parakeet on this Mac, or OpenAI
      ↓
timing alignment     for a model that returns text alone, on this Mac
      ↓
speaker separation   FluidAudio offline diarizer, on this Mac
      ↓
speaker recognition  matched against voice profiles held locally
      ↓
editable transcript  correct a whole speaker or a single line
      ↓
enrichment           optional: titles, summaries and notes from a cloud model
```

Nothing before the last step needs an API key or a network connection. On
macOS 26 and later a fresh install downloads about 22 MB and transcribes with
Apple's system speech models; choosing Parakeet downloads about 481 MB.
Recording works while a download happens and meetings queue until it finishes.

Settings carry one processing knob. Speaker separation follows the
transcription choice: local for every engine except `gpt-4o-transcribe-diarize`,
whose one request also labels the speakers. Neither is tied to enrichment, and
selecting OpenAI does not move voice profiles off the machine: a cloud diarizer
returns speaker labels and no vectors, so MeetTape extracts them locally over
the intervals it reported.

On a 65-minute meeting the whole local pipeline took 4.5 minutes on an M2 Pro,
peaking under 1 GB and under two of ten cores, with no thermal throttling.
Capture always outranks processing: a job waits between stages while a recording
is live, and one meeting is processed at a time.

Two local engines are offered, picked on the Processing page. On macOS 26 and
later the default is Apple's SpeechAnalyzer: the speech models come with the
system, so a fresh install transcribes its first meeting with nothing to
download. Parakeet TDT v3 is the accuracy pick and the default before macOS 26:
word timings of its own, 25 languages, about 460 MB. Cohere Transcribe and
Whisper Large-v3-Turbo keep working on installs that already chose them and are
no longer offered to new ones. In the cloud, `gpt-4o-transcribe-diarize` is the
default and returns words and speakers from one request; `gpt-transcribe` is
the alternative for clear recordings and vocabulary hints, with its timings
aligned on this Mac. Word timings, which speaker attribution depends on, are
protected in every configuration: native from Apple, Parakeet and Whisper,
aligned for text-only models.

### How the engines measured

Every offering decision above comes from `meettape-eval bench` runs of the real
pipeline over the `deciding` suite: 14 meetings from AMI's held-out evaluation
partition, ICSI and NOTSOFAR-1, none of them in any local candidate's training
data, spanning 4% to 46% overlapped speech. Medians below; per-speaker tcpWER
counts every word, overlap included, and lower is better everywhere except
attribution and RTFx. Local finalists are the mean of three runs per case.

| Engine | tcpWER | WER (no filler) | Attribution | Repeated 8-grams | RTFx | Download |
|---|---|---|---|---|---|---|
| Parakeet TDT v3 | 68.6% | 42.6% | 85.1% | 7 | 48 | 0.5 GB |
| Apple SpeechAnalyzer | 69.9% | 47.3% | 86.5% | 32 | 46 | none |
| Whisper large-v3-turbo | 70.1% | 48.8% | 85.3% | 31 | 13 | 0.6 GB |
| gpt-4o-transcribe-diarize (cloud) | 70.5% | 47.8% | 80.3% | 27 | 1.9 | none |
| whisper-1 (cloud) | 72.5% | 45.3% | 85.0% | 24 | 16 | none |
| Cohere Transcribe | 88.1% | 54.1% | 86.4% | 178 | 5.7 | 4.6 GB |

whisper-1 through the API beat local Parakeet on zero of the fourteen cases,
which is why it moved behind Custom. gpt-transcribe returned empty output for
chunks of the five hardest meetings across two attempts and is scored on its
nine survivors (84.3% tcpWER); the pipeline retries such a meeting rather than
filing it with words missing. The one cloud advantage measured is
`gpt-4o-transcribe-diarize` on extreme overlap, where it beat Parakeet on 9 of
14 cases while attributing speakers worse and running slower than real time.
The suites, checksums and scoring rules live in `Benchmarks/`.

## Speaker recognition

Each speaker MeetTape separates out is matched against the voices it holds. A
match needs three things at once: a similarity of at least 0.70, a clear margin
over the next-best candidate, and at least 45 seconds of that person's speech in
the meeting. The margin is not optional. Over a gallery of 326 verified-distinct
speakers the highest wrong match scored 0.957, above the true speaker's own
0.951, so a similarity threshold on its own names the wrong person.

Confidence is shown as High, Likely or Unknown, never as a percentage. The number
behind it is a cosine similarity whose genuine and impostor ranges overlap at the
top, and rendering 0.92 as "92% sure" would imply a calibration that does not
exist.

A voice with at least 45 seconds of clean speech is remembered even when nobody
knows whose it is. If it turns up in a later meeting it becomes a recurring
identity, and naming it later updates every meeting it appeared in without
re-transcribing anything.

Only two things ever add to a voice profile: the microphone track of a remote
call, where the speaker is the local user by construction, and a speaker name a
person confirmed. A recognition result, at any confidence, is a read. That rule
is what stops one wrong automatic match from compounding into a permanently wrong
profile.

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

Always build through the scripts. They source `scripts/spm-env.sh`, which
repairs two Command Line Tools defects that otherwise stop the speech
dependencies linking, and exports flags a bare `swift build` would miss.
`scripts/eval.sh` is a developer tool for checking the local stack's measured
numbers against real audio; see [CLAUDE.md](CLAUDE.md).

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

Optional. With no key at all MeetTape records, transcribes, separates speakers
and recognizes voices; what a key adds is titles, descriptions, summaries, notes
and textual speaker suggestions, plus the option of running transcription or
speaker separation in the cloud instead of locally.

The Cloud tab in Settings accepts an API key, stores it in the login keychain,
and provides a Test Connection button that fetches a single model description to
confirm both the key and access to that model.

Model identifiers are settings rather than constants:

- transcription defaults to `gpt-transcribe` on a new installation, OpenAI's
  most accurate transcription model. It returns text with no timings, so the
  local CTC aligner recovers them, the same way it does for local Cohere.
  `gpt-4o-transcribe-diarize` is the self-contained option with nothing to
  download, and `whisper-1` remains for word timings straight from the API. An
  existing installation keeps whichever model it was configured with: picking
  one is what consents to any download it needs;
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

The top level holds what a person opens directly; everything the application
maintains is under `raw/`.

```
2026-08-18-1418-slack-huddle-engineering/
├── transcript.md             rendered transcript for reading
├── recording.m4a             mixdown of both tracks, AAC, regenerated on demand
├── notes.md                  user notes, which no processing step modifies
├── summary.md                generated summary
└── raw/
    ├── manifest.jsonl        append-only record of every capture event
    ├── audio/
    │   ├── mic.m4a           source audio for the local microphone
    │   └── system.m4a        source audio for the meeting application
    ├── api/                  API responses as received
    ├── alignments/           word timings recovered for a model that returned none
    ├── metadata.json         title, participants, calendar link, processing state
    ├── transcript.raw.json   transcription output as returned, with word timings
    ├── diarization.raw.json  who spoke when, as the diarizer decided it
    ├── speakers.map.json     speaker names and per-line corrections
    └── transcript.json       canonical transcript on a single timeline
```

While a meeting records and processes, `raw/segments/` holds the source audio
as 30-second float32 CAF files, the format that survives a kill mid-write. Once
processing completes, each track is transcoded to `raw/audio/` as AAC mono at
16 kHz, the rate every model reads, verified against the manifest, and the
segments are deleted. A 72-minute meeting is about 90 MB instead of the 2.4 GB
the PCM held.

The manifest is the authoritative timeline; audio container headers are not
trusted. The track archives, the manifest lines, the raw transcription and
diarization output and any imported original file are never modified after they
are written. The Markdown files, `summary.md` and `recording.m4a` are derived
from those inputs and can be deleted safely.

Renaming a speaker updates `speakers.map.json` and re-renders the transcript, and
so does correcting a single line. Neither re-transcribes the audio nor modifies
the raw diarization. Re-analyzing speakers writes a new analysis alongside the
old one rather than replacing it.

Voice profiles are deliberately absent from this list. They live in
`~/Library/Application Support/MeetTape/Speakers/voices.sqlite` and are never
written into a meeting folder or an export.

## Privacy

By default no audio leaves the machine. Transcription, speaker separation and
voice recognition all run locally. Audio is uploaded only if you select OpenAI
for transcription or speaker separation in Settings; transcript text is uploaded
only if you switch on titles, summaries or notes. There is no MeetTape account,
no telemetry and no analytics.

Voice profiles are 256-number vectors derived from speech. They are not audio and
cannot be turned back into it, but they are a stable identifier for a specific
person, so they are treated as biometric data: stored under Application Support,
excluded from every meeting folder and every export, and never uploaded. Settings
offers "Forget learned voice" separately from deleting a person, so a name can
stay on past transcripts while the biometric goes away.

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
