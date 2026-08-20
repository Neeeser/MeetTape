# Verification status

This file records which behaviour has been exercised and which has only been
implemented. An item is listed as verified only if it was run and its result
observed.

Machine: MacBook Pro (Mac14,9), Apple M2 Pro, macOS 27.0, Command Line Tools
only, no code-signing identity.

## Automated

`./scripts/test.sh` runs 284 tests, all passing, in about 10 seconds.
Fifteen further tests are skipped unless explicitly enabled, as described below.

`cd extension && npm test` runs 10 tests, all passing.

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
| The tuned `warmStartFa` is what the diarizer is configured with | `LocalConfigurationTests` |
| No speaker count is passed automatically, from any source | `LocalConfigurationTests` |
| Special tokens are skipped and word timings are on | `LocalConfigurationTests` |
| Models resolve under Application Support and never Documents | `LocalConfigurationTests` |
| Naming needs score, margin and duration together | `SpeakerIdentityTests` |
| Under ten seconds of speech is Unknown at any score | `SpeakerIdentityTests` |
| Two candidates 0.006 apart are never named automatically | `SpeakerIdentityTests` |
| A listed participant relaxes the margin and nothing else | `SpeakerIdentityTests` |
| A recurring unnamed voice links at a stricter bar than a name | `SpeakerIdentityTests` |
| A High automatic match never adds a vector to a profile | `SpeakerIdentityTests` |
| A named profile refuses a vector nobody stood behind | `SpeakerIdentityTests` |
| Corrected lines accumulate and enrol once, past 45 seconds | `SpeakerIdentityTests` |
| Naming a recurring voice keeps its history and its profile | `SpeakerIdentityTests` |
| A merge redirects rather than rewriting, and can be undone | `SpeakerIdentityTests` |
| Forgetting a voice keeps the name on past transcripts | `SpeakerIdentityTests` |
| A voice heard once expires; one heard twice does not | `SpeakerIdentityTests` |
| A word goes to the interval it overlaps most, then the nearest | `SpeakerCorrectionTests` |
| A segment spanning two speakers is split at the change | `SpeakerCorrectionTests` |
| Segments that already name a speaker are left as they are | `SpeakerCorrectionTests` |
| Correcting one line leaves every other line in its cluster alone | `SpeakerCorrectionTests` |
| A line correction survives the transcript being reassembled | `SpeakerCorrectionTests` |
| A voice match never overwrites a person's answer | `SpeakerCorrectionTests` |
| Transcription and speaker separation are chosen independently | `BackendSelectionTests` |
| A settings file from an older build keeps every field it had | `BackendSelectionTests` |
| Nothing heavy starts while a recording is live | `BackendSelectionTests` |
| One heavy job holds the lock at a time | `BackendSelectionTests` |
| A local run attributes every word and splits at speaker changes | `LocalPipelineTests` |
| A local run leaves no voice vectors in the meeting folder | `LocalPipelineTests` |
| A cloud diarization still records speakers for voice memory | `LocalPipelineTests` |
| Re-analysing keeps the previous analysis and the words | `LocalPipelineTests` |
| A re-analysis renumbers clusters and the voice can still be taken back | `VoiceEvidenceTests` |
| A correction records the audio it confirmed, not the label | `VoiceEvidenceTests` |
| A vector keeps standing while most of its audio is still its owner's | `VoiceEvidenceTests` |
| Corrections add up until too little of the audio is left | `VoiceEvidenceTests` |
| Audio on one track never retracts a vector from the other | `VoiceEvidenceTests` |
| A merge moves who owns a vector, not what it was derived from | `VoiceEvidenceTests` |
| Undoing a merge gives each identity back its own audio | `VoiceEvidenceTests` |
| Removing one vector rebuilds the centroid over what is left | `VoiceEvidenceTests` |
| A store written before evidence existed opens, keeping its people | `VoiceEvidenceTests` |
| One candidate is offered rather than named automatically | `SpeakerIdentityTests` |
| Two non-overlapping clusters may be one person; overlapping ones may not | `SpeakerIdentityTests` |
| A voice the diarizer split in two is remembered once | `SpeakerIdentityTests` |
| An ambiguous split is remembered as nothing rather than as two | `SpeakerIdentityTests` |
| Nothing to check bleed against is a refusal, not a pass | `SpeakerIdentityTests` |
| Both halves of a reconnected call are one meeting, in order | `ReconnectTests` |
| The folded half is reachable by its own identifier | `ReconnectTests` |
| Separating a continuation gives back two meetings and loses nothing | `ReconnectTests` |
| Linking does not rewrite either recording's own duration | `ReconnectTests` |
| A batch correction is applied to every line or to none | `LocalPipelineTests` |
| The local transcriber reads the audio and nothing is uploaded | `LocalPipelineTests` |
| The panel resolves the archive once, not on every render | `UITests` |
| Closing the panel does not overwrite a note added elsewhere | `UITests` |
| A mix that cannot finish leaves no file to be mistaken for one | `AudioTests` |
| A correction on the second half of a split call reaches that half | `ReconnectTests` |
| One meeting contributes one vector however often it is confirmed | `VoiceEvidenceTests` |
| Giving audio back un-debits the owner it came back to | `VoiceEvidenceTests` |
| Naming a cluster leaves the lines already given to somebody else | `LocalPipelineTests` |
| Undoing a line correction hands the audio back rather than orphaning it | `LocalPipelineTests` |
| Re-analysing a cloud-diarized meeting changes who the lines belong to | `LocalPipelineTests` |
| Switching backend and retrying does not transcribe a track twice | `LocalPipelineTests` |
| Saying the microphone was somebody else takes back what it taught | `LocalPipelineTests` |

## Exercised against real hardware and the real API

**Capture chain.** `MEETTAPE_LIVE_CAPTURE=1 ./scripts/test.sh --filter LiveCapture`
runs the shipping `CaptureEngine` with `AVAudioEngine` and a CoreAudio process
tap for ten seconds. Verified: microphone audio recorded, segments rotated, the
manifest closed with no open segments, every segment's frame count matching the
file on disk, the recording reading back through the processing path with a
non-zero peak, and the pre-roll captured before commit flushed into the
recording.

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

**A real Google Meet call.** A call in Firefox, with no extension loaded, was
detected through window titles and microphone state: the log shows
`google_meet:1:native` then `google_meet:2:native`, candidate then confirmed. The
meeting directory carries the meeting code from the window title, and the
manifest records 15 s of microphone and 14.9 s of meeting audio flushed from the
pre-roll at the moment of confirmation. The microphone delivered three-channel
buffers during that call, which is the format that used to read back as silence.

**Speech through the microphone, end to end.** A recording started from the menu
bar while speech played through the built-in speakers. The 0.5-second energy
envelope of the recorded track shows background at -59 dBFS, both spoken
passages at -43 dBFS, and the pause between them in the right place. The meeting
directory, its manifest and its segments were written, finalisation reached
`audio_safe`, and processing then stopped at the missing API key.

**Aggregate device buffer shape.** With a virtual output device present, the
process tap arrives as two streams, `[8ch/16384B, 2ch/4096B]`, the device's own
stream first and the tap's second. Reading the first stream's byte count as
frames recorded 334 seconds of meeting audio during 42 seconds of wall clock.
After the fix, a 26-second recording reports 26.2 s on both tracks against a
26.3 s host-time span.

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

The live API runs below were repeated on 2026-08-19 against the current
pipeline: concurrent chunk uploads, `gpt-5.6-luna` as the metadata model, and
low reasoning effort on the metadata requests. All of them passed, which also
confirms that the responses endpoint accepts that model identifier with a
`reasoning` parameter.

**Long meeting, live.** `MEETTAPE_LIVE_LONG=1` put 62 minutes of synthesised
speech through the chunked pipeline against the real API: four diarization
chunks, three in flight at a time, merged and de-duplicated into one
transcript. Wall time was 13.7 minutes end to end, including local synthesis,
the energy profile and the chunk exports. The same pipeline sending chunks one
at a time took over ten minutes for a 25-minute file.

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

**A real Slack Huddle through the audio-only path.** With accessibility and
screen recording denied, a two-minute huddle against a second account was
detected from the helper process's audio streams alone: candidate when the
preview opened the microphone, confirmed 25 seconds after the two-way audio
began, committed to disk, and finished with `provider_ended`. The end path was
measured against the same huddle: the helper released its input stream the
moment the huddle ended and its output stream 12 seconds later, evidence went
to none 15 seconds after the leave, and the session finalised 97 seconds after
that (6-second end grace plus the 90-second reconnect window). These runs
predate the change that pauses capture during the reconnect window; the timing
of the evidence decay is what they establish.

**Echo cancellation.** Measured A/B on the built-in microphone and speakers.
Without voice processing, speech played through the speakers into an open
microphone recorded at -43 dBFS against a -59 dBFS room floor, and whisper
transcribed it onto the local track. With `setVoiceProcessingEnabled` and
ducking disabled, the same test left the microphone track at the noise floor
(-55 to -65 dBFS) for the full recording, with no speech-shaped energy in
either playback window. Enabling the voice unit changed the input format after
the writer opened, which the format-mismatch rotation absorbed in half a
second with one coalesced restart and no storm. The near-end case, a person
speaking while the far end also plays, has not been measured; nobody was in
the room.

**How meeting applications release audio on leave.** Measured with a CoreAudio
process probe on macOS 26: Firefox acquires the input stream on the Meet
prejoin screen and releases it within a second of leaving the call, keeping
only an output stream, and Slack's helper releases input immediately and
output within 12 seconds. Neither application holds a stream that would keep
producing meeting evidence after a leave.

**On-device models.** `MEETTAPE_LOCAL_MODELS=1 MEETTAPE_LIVE_FIXTURE=... ./scripts/test.sh
--filter LocalModels` downloads and loads the real models and runs them against
the locally synthesised three-voice fixture. Measured on this machine:

| Step | Result |
|---|---|
| First install | 246.1 s, 626 MB Whisper plus 21 MB diarizer, into `~/Library/Application Support/MeetTape/Models` |
| Transcription of 38.5 s | 5.4 s, word timings present, no special tokens in the text |
| Diarization of 38.5 s | 0.58 s, RTFx 66, 256-dimension vectors returned, `warmStartFa` recorded as 0.2 |
| Warm reload with no download | 5.7 s for both models, from a manager with nothing cached in memory |

The install time matches the 244.9 s the probe measured for the same cold path,
almost all of it Core ML specializing the model for the Neural Engine rather than
downloading. That cost returns whenever the binary's identity changes, which
under ad-hoc signing means every rebuild: the first transcription after one took
184 s, and two consecutive runs of the same binary in fresh processes took 8.6 s
between them. A signed build pays it once, not per launch.

**Speaker separation on real calls.** `scripts/eval.sh diarize --audio FILE`
runs the same file at the library default and at the shipping value. Against the
eleven authorized recordings from the local-processing probe, and against the
synthetic files built from seven identified voices where the true count is known:

| Recording | True speakers | Fa=0.07 | Fa=0.20 | Agreement |
|---|---:|---:|---:|---:|
| Slack huddle, 15 min | 2 | 2 | 2 | 100% |
| Remote call, 21 min | 2 | 2 | 2 | 100% |
| Remote call, 12 min | 2 | 2 | 2 | 100% |
| Remote call, 17 min | unknown | 2 | 3 | 99.8% |
| In-person, 28 min | 2 | 2 | 2 | 100% |
| Room recording, 41 min | unknown | 3 | 4 | 99.9% |
| Synthetic | 4 | 3 | 5 | 76% |
| Synthetic | 5 | 3 | **5** | 71% |
| Synthetic | 6 | 4 | **6** | 75% |
| Synthetic | 7 | 6 | **7** | 92% |

On the two-speaker calls that make up most real use, the two values produce
byte-identical output, so the change costs nothing there. The agreement column is
softer than it looks: it was computed by fixing each cluster's counterpart on
first sight, which credits a merge as complete agreement, so it could not have
shown a merge in one of the two directions. `scripts/eval.sh` now assigns each
cluster its majority counterpart and lets each counterpart be claimed once, but
the numbers in this table predate that and have not been recomputed. The speaker
counts either side of them are direct and unaffected. On the files with known ground truth the
mean absolute count error falls from 1.5 to 0.25, and the tuned value hits the
exact count at five, six and seven speakers where the default under-counted by
two, two and one. The one over-count is at four speakers, which is the
recoverable direction: a split is one merge, a merge is not undoable without
re-analysis.

This is the acceptance test the implementation brief asked for, and it agrees
with the probe. It is still one machine and one corpus.

**Offline.** The release binary was run under `sandbox-exec` with
`(deny network*)`, after verifying the sandbox blocks the network at all:
`curl https://huggingface.co` returns 000 inside it and 200 outside. With the
network denied, transcription produced 109 words with word timings from the
38.5-second fixture and speaker embedding produced 256-dimension vectors that
separated the two tracks at 0.445. Nothing in the local path reaches the network
once the models are installed.

**Adversarial review.** Reviewers were run against the implementation in four
rounds, one per failure class each round: voice-profile poisoning, threshold
mistakes, raw-data mutation, store correctness, concurrency, privacy, model
handling, compatibility with existing meetings and settings, and test quality.
Each round reviewed the previous round's fixes, and each round found that some
of them had introduced new defects.

| Round | Real defects | Of which introduced by the previous round's fixes |
|---|---:|---:|
| 1 | 22 | — |
| 2 | 12 | 4 |
| 3 | 7 | 2 |
| 4 | 8 | 5 |

Every fix carries a regression test, watched red for the defect's own reason
before the fix and green after. The most serious found across the four rounds:

- The default configuration could not finish a meeting without an API key. Both
  speech backends default to local and the speaker-suggestion setting defaults
  on, so every meeting failed at a cloud stage that ran before the step which
  writes the markdown and the mixdown.
- The microphone track enrolled whoever dominated it. On a device pairing where
  echo cancellation falls back to plain capture, a presenter talking through a
  long call was written into the local user's profile, human-verified.
- A cluster's vector stayed in the first name's profile forever. Correcting a
  mis-click left that voice inside the wrong person, and the next meeting
  auto-named them as the person who had been corrected away.
- Choosing the cloud diarizer uploaded the meeting even with transcription set
  to Local, and on an imported recording nothing was transcribed locally at all.
- Rebuilding a transcript dropped the diarization and collapsed every speaker.
- The expiry predicate for unnamed voices was inverted, so nothing expired, and
  it selected human-confirmed rows for deletion.
- Capture lifecycle actions shared an ordered queue with processing jobs, and
  later, progress ticks rescanned the whole archive on the same actor.
- A reconnected meeting was folded into the earlier one, which moves no audio,
  and then never transcribed.
- An enrichment failure took the readable transcript and the mixdown with it.

The review cost about as much as the implementation. That ratio is the finding:
this subsystem has many quiet failure modes, and a fix in it is as likely to
need review as the code it repairs.

## Not verified

The following behaviour is implemented but has not been exercised, and should not
be assumed to work.

- **A real Slack Huddle with accessibility granted.** The `Leave Huddle` control
  path is covered by tests written against recorded observations. A real huddle
  has been recorded end to end through the audio-only fallback (below), but not
  through the accessibility path.
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
- **Voice recognition across real meetings over time.** The thresholds come from
  public corpora and the local corpus of eleven authorized recordings. Nobody has
  yet been recognized by MeetTape in a meeting weeks after being named in another
  one, which is the feature working end to end. The measured pieces are there;
  the passage of time is not.
- **The recurring unnamed voice lifecycle in the product.** Creating a candidate,
  promoting it on a second meeting, naming it, and seeing every earlier meeting
  update are covered by tests against the store and the service. No user has
  walked that path through the panels.
- **Merging and separating identities from the UI.** The data model, the
  tombstone and the name restoration have tests. The People tab exposes rename
  and forget-voice, and merging is available only through the runtime API.
- **The participant soft prior on real meetings.** Relaxing the margin from 0.10
  to 0.05 for a listed participant is reasoned from open-set results, not
  measured. It is deliberately one value in one place.
- **A real meeting with ten or more people.** The speaker-count behaviour above
  eight comes from VoxConverse and from synthetic files. No such call exists in
  the local corpus.
- **Processing during a live recording.** The gate and the single job slot have
  tests, and the queue parks between stages. Whether a full local pipeline
  running alongside a live capture drops audio has not been measured on hardware.
  Note the shape of the guarantee: a stage does not *start* during capture, but a
  stage already running does not stop, so a meeting beginning part-way through a
  four-minute transcription shares the Neural Engine until that stage ends.
- **A reconnected call as one meeting, on hardware.** The two recordings are now
  linked rather than folded: Recent Meetings shows one row reporting both halves'
  audio, the panel renders both transcripts in order, opening the continuation by
  its own identifier resolves to the conversation, and separating it again is
  clearing one field on each side. `ReconnectTests` covers all of that against
  the storage layer and the runtime. What has not happened is a real call
  dropping and being rejoined with this build running.
- **A one-voice gallery is never named automatically.** With a single profile in
  voice memory there is no runner-up, so nothing reaches High and the first
  recognition of a recurring voice waits until memory holds two. Every meeting
  with two qualifying speakers seeds two candidates, so this is a first-week
  condition rather than a lasting one, but it has not been watched happening.
- **A voice the diarizer split across two clusters.** Both halves resolving to
  one identity, and two clusters that overlap in time refusing to, are covered by
  tests over synthetic vectors. No recording in the local corpus is known to
  contain a speaker the tuned clusterer splits, so the case that motivates the
  rule has not been observed end to end.
- **The bound on how long a prejoin holds processing.** Capture arms on entering
  the candidate state, and processing stands back from it for two minutes. That
  covers the measured twelve seconds between Slack opening the microphone and a
  join, but the value itself is reasoned, not measured, and a longer prejoin
  releases processing while the microphone is still open.
- **Calendar matching.** `CalendarService` reads EventKit and scores events
  against a recording's time window, and it has no tests and has not been run
  against a real calendar. A wrong match shows the wrong title and attendees on a
  meeting; the recording and transcript are unaffected.
