# Capture correctness and echo subtraction

Date: 2026-09-03. Approved in chat by Andrew. Not committed.

## Problem

Pipit records two tracks. The mic track is the raw microphone. The system
track is a process tap on the meeting app. On speakers the far end enters the
mic through the air, so the mic track holds both people. Every echo change
from PR #15 to PR #50 guessed, after transcription, which words were the far
end and deleted them. Guessing wrong deleted the user. PR #48 removed the
voice-processing unit's ducking, which raised the far end about 9 dB on every
later recording, and the 0.4 dB echo clause calibrated under ducking then
deleted all of the user's words on the first huddle after it.

Three capture defects sit under that. The tap's stream is picked by channel
count, so a sub-device with a matching input stream wins and records silence.
A tap delivering digital zero while its target reports output is never
noticed. The mic track keeps channel 0 of whatever input layout macOS
presents, which on a raw three-channel built-in mic is a capsule about 30 dB
down, and the setting meant to govern device choice is never read.

## Decisions

- The cleaned mic is a derived file beside the immutable raw mic. Raw audio
  is never rewritten.
- Every recording with both tracks is re-processed once the new pipeline
  lands. Hand-typed names and line corrections are preserved. The three
  silent-tap recordings are skipped.
- The microphone is the system default input device, resolved explicitly at
  each build. The `preferBuiltInMicrophone` setting is deleted.
- One PR per step, merged before the next starts, one review pass each.
  A review finding outside the PR's purpose is noted for a later PR.

## PR 1. Capture correctness

### Tap stream identity

`RemoteAudioSource.bind` builds an aggregate from the default output device
plus the tap. The IOProc's buffer list holds one buffer per input stream,
sub-device streams first, then the tap's. Today `makeBuffer` takes the first
buffer whose channel count equals the tap's, which is the sub-device's own
input stream whenever it has one with that count. Both Jump Desktop devices
on this Mac are bidirectional with 8 channels, and the code comment records a
MacBook Pro output device presenting an 8-channel input stream ahead of the
tap.

After creating the aggregate, `bind` reads the aggregate's input stream count
from CoreAudio. The tap's buffer index is that count minus one, the last
stream. `bind` returns a `RemoteTapBinding` carrying the format, the stream
count and the tap index. `makeBuffer` takes the index and reads that buffer.
If the indexed buffer's channel count does not match the tap format, the old
channel-count match is the fallback and the mismatch is logged once. The
`remote_bind` manifest event gains `streamCount` and `tapStreamIndex`, both
optional so old manifests still decode.

Test: a buffer list of a silent stereo sub-device buffer followed by a stereo
tap buffer with audio, index 1, returns the tap's audio. Red with the old
selection, green with the new.

### Silence while producing

`CaptureEngine.receive` computes the peak sample of each remote packet with
`vDSP_maxmgv` and passes it to the remote coordinator. `RemoteRecoveryPolicy`
records when a run of exactly-zero buffers began while the bound target
reports running output. After 20 seconds of that it decides one rebind with a
new reason, `silentWhileProducing`. If the silence continues 20 seconds after
that rebind, health goes to `degraded` with a detail string, and
`warnings()` reports a new `CaptureWarning.remoteSilentWhileProducing(seconds:)`
which reaches `captureWarnings` through the existing warning path. Any
non-zero buffer ends the episode. A target that is not producing keeps
today's `idleButBound` behaviour and never triggers this.

Tests, with `FakeProcessTap`: zero buffers for 25 s under a producing target
rebind once with the new reason; continued zeros yield the warning and
degraded health; one non-zero buffer clears both; zero buffers under a
non-producing target do nothing new.

### Microphone device and channel

`MicrophoneSource.build` reads the default input device ID and sets it on the
input node's audio unit with `kAudioOutputUnitProperty_CurrentDevice` before
`prepare`. A failure to set it throws `microphoneEngineStartFailed`. After a
successful build the coordinator reports the device through a new delegate
call and `CaptureEngine` writes a `mic_bind` manifest event holding the
device UID, name, sample rate, channel count and the rebuild reason. The
event round-trips through the manifest reader and is added to the round-trip
test's event list.

Channel choice moves to one place. In `TrackAudioStream.openNextSegmentGroup`,
a source with more than two channels and no layout is scanned for up to
30 seconds of its first file, the channel with the highest RMS is chosen, and
the converter's channel map repeats that channel for every target channel.
The choice and the channel count are logged. Mono and stereo are unchanged.

Test: a three-channel CAF with a tone on channel 2 and silence elsewhere,
read to mono through `TrackAudioStream`, holds the tone. Red before, green
after.

`preferBuiltInMicrophone` is removed from `AppSettings`, the decoder, and
`RecordingSettingsPane`. A test loads a settings file that still carries the
key and expects the other settings to survive.

## PR 2. Echo subtraction

Wrapper fixes in the vendored shim from PR #51: the channel-pointer arrays are
sized to the configured channel count, and the exported statistic is
`echo_return_loss_enhancement`, exposed to Swift as `echoRemovedDB` with a doc
that says it is what the canceller removed. A second test feeds a synthetic
near-end voice overlapping the echo and asserts it survives within 3 dB.

A new pipeline stage, `cancelling`, runs after `audio_safe` and before
transcription for sources whose mic should hold the local user alone. It
reads both tracks at 16 kHz mono aligned by the recording timeline through
`TimelineTrackReader`, feeds the far end and the mic block by block, and
writes `raw/audio/mic.cleaned.m4a` with `TrackArchiveExporter.Settings.archive`.
Its frame count and first-frame host time equal the raw mic track's. Metadata
records it as `cleanedMic: AudioArchive.Track?` and the stage that produced it.

`MeetingRepository.trackAudioLocation(track: .mic)` returns the cleaned track
when metadata records one. Transcription, speech evidence, diarization, voice
enrolment and the mixdown read through that call and change nothing.
Compaction and archive verification call a new `rawTrackAudioLocation`.

Bypass: when the far end never rises above the silence floor, the stage
skips and records the reason. When the median `echoRemovedDB` over windows
where the far end was above the floor is under a threshold, the cleaned file
is deleted and the raw mic stays in use. The threshold is set from Andrew's
speaker recordings and one headphone recording he makes for the purpose.

## PR 3. Delete the guessing stack

Removed: `EchoReturnLossProfile.swift`; the echo return loss pass, delay
search and measure in `SpeechEvidenceBuilder`; `SpeechEvidence.micEchoReturnLoss`;
`LocalSpeechPolicy.echoReturnLossDB`, `sustainedMarginDB` and the level and
echo clauses; `SpeechReading.loudestFarDB`, `medianDifferenceDB` and
`echoReturnLossDB`; in `TranscriptAssembler` `trimmingEcho`, the bridging,
the keep-length rule, `isEcho` and the echo reference plumbing.
`SensorTimeline.markingSelf` computes its self-share from the detector alone.
Kept: `holdsWords`, the voice-activity clause, `farEndCarriesSignal`,
`micHoldsLocalUserAlone`. Old `speech.json` files with the dead field decode.
`SpeechGateTests` and `EchoTests` shrink to what remains. `GateCommand` in
`pipit-eval` follows the policy.

`pipit-eval reprocess --meeting DIR` clears speech evidence and derived
transcripts, runs cleaning, transcription and assembly, and preserves
human-origin names and line corrections. Order of the re-run: the two
September 3 meetings first for Andrew to read, then the other 24 meetings
with both tracks. The three silent-tap meetings are skipped.

## PR 4. Echo evaluation set

`pipit-eval echo --meeting DIR` prints far-end removal in dB over windows
where only the far end spoke, solo-speech loss in dB, overlap loss in dB, and
the share of cleaned-mic trigrams that also appear on the far-end transcript.
A checked-in JSON of hand-marked spans for two of Andrew's meetings, without
audio, gives the loss numbers a human reference.

## Out of scope

Sensor precedence over diarization, the identity model, the UI freeze, and
Bluetooth or USB drift measurements beyond the one headphone recording.
