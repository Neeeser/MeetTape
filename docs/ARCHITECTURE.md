# Architecture

Pipit runs as one macOS process with separate modules for detection, capture,
storage, speech processing, and interface code. A small native host relays
browser events to the application.

## Modules

```text
PipitApp
└── PipitUI
    └── PipitServices
        ├── PipitDetection
        ├── PipitIntegrations
        ├── PipitLocalAI
        ├── PipitSpeakers
        ├── PipitAudio
        └── PipitCore

pipit-nativehost    browser event relay
pipit-eval          benchmark and diagnostic tool
```

`PipitCore` imports Foundation and contains decisions that do not require I/O.
It owns session policy, manifests, storage models, chunk planning, transcript
assembly, and recovery decisions.

The other modules own external resources and state. `PipitAudio` owns audio
devices and files. `PipitDetection` collects meeting evidence. Integrations own
system and network APIs. `PipitLocalAI` owns on-device speech models.
`PipitSpeakers` owns the local voice database. `PipitServices` connects those
modules to the application lifecycle.

## Meeting detection

Detection adapters report evidence from accessibility controls, window titles,
audio process state, and the browser sensor. They do not start or stop capture.
`SessionController` combines the evidence and owns the recording lifecycle.

```text
idle -> candidate -> recording -> reconnecting -> ended
          |                            |
          └-> discard                  └-> append another recording
```

A candidate starts both audio sources into a 15-second memory ring. Confirmation
creates the meeting directory and flushes the ring to disk. An abandoned
candidate leaves no files. Manual recordings ignore provider evidence.

When a call disconnects, Pipit closes the current recording and waits for a
rejoin. A rejoin creates another immutable recording under the same logical
meeting. Linking and separating recordings changes metadata and does not rewrite
audio.

## Audio capture

Pipit records two sources against the same host clock:

```text
microphone       -> AVAudioEngine -> SegmentWriter(mic)
meeting process  -> CoreAudio tap -> SegmentWriter(system)
```

The streams stay separate during capture. Pipit aligns and mixes them after the
meeting using the host timestamps stored with each segment.

Audio callbacks copy buffers onto a private serial queue. File creation,
manifest writes, device rebuilds, and teardown run on the capture control queue.
Audio callbacks perform no file I/O.

The microphone and process tap use different health policies. Missing microphone
buffers indicate a failed input. A process tap may remain silent while its
application produces no audio. Pipit rebuilds the tap only when the application
reports output and callbacks stop arriving.

Capture writes 30-second CAF segments and appends lifecycle records to
`raw/manifest.jsonl`. Each segment records its own sample rate and frame count.
Recovery reads the manifest and file lengths, adopts complete audio after a
crash, and resumes the meeting from its last durable state.

## Storage

The default meeting root is
`~/Documents/Pipit/Meetings/YYYY/MM/<meeting>/`. Users can change it in
Settings.

```text
meeting/
├── transcript.md
├── recording.m4a
├── notes.md
├── summary.md
└── raw/
    ├── manifest.jsonl
    ├── audio/
    ├── api/
    ├── alignments/
    ├── metadata.json
    ├── transcript.raw.json
    ├── diarization.raw.json
    ├── sensors.raw.json
    ├── speakers.map.json
    └── transcript.json
```

Source audio, manifest entries, raw model output, and imported originals are
immutable. Titles, notes, speaker mappings, and meeting metadata are mutable.
Markdown, summaries, and the mixed recording are derived files and can be
regenerated.

Completed source tracks are compacted from CAF segments into AAC after Pipit
verifies their decoded duration. Segment deletion starts only after the archive
and metadata are durable. An interrupted compaction resumes during startup.

Voice profiles are stored separately at
`~/Library/Application Support/Pipit/Speakers/voices.sqlite`. Meeting folders
and exports contain no voice vectors.

## Speech processing

```text
finalizing -> audio_safe -> transcribing -> diarizing
           -> resolving_speakers -> enriching -> complete
```

`audio_safe` marks the point where the recording is durable. Network work starts
only after this state. Each later stage records its state and can resume after a
failure.

Local processing uses Apple SpeechAnalyzer on supported macOS versions or
Parakeet through FluidAudio. Speaker separation runs locally unless the selected
cloud model returns words and speakers together. Voice matching stays local for
every configuration.

Long recordings are divided into overlapping chunks when a backend requires it.
Completed chunks are written as they arrive. Transcript assembly places both
tracks on one timeline, removes repeated overlap text, and assigns words to
speaker intervals.

Pipit runs one processing job at a time. A queued job waits between stages while
capture is active. Capture keeps priority over speech work.

Optional enrichment reads the canonical transcript and can produce a title,
summary, notes, and textual speaker suggestions. An enrichment failure leaves
the recording and transcript available for retry.

## Speaker identity

Diarization writes immutable speaker intervals. `speakers.map.json` adds mutable
cluster mappings, line corrections, and transcript boundaries above that raw
output. Re-analysis appends another diarization run and keeps the previous run.

`sensors.raw.json` records what the meeting client itself said: the roster keyed
by the platform's own identifier, who was seen unmuted, and who held the floor
when. Mute state is kept as a record of what the client reported and is not
consulted when deciding who spoke, because holding the floor settles that and a
tile whose overlay never resolved would otherwise outrank it.
It is immutable like the diarization beside it, because it is evidence about a
recording rather than a conclusion about one.

Three things read it. Word attribution assigns each transcribed word on the
remote track to the sensor turn covering it, keyed on the platform's own
participant identifier, and the diarizer attributes only the words no turn
covers: gaps in the readings, overlap, and every meeting recorded without a
readable client. Voice enrollment embeds each participant's turns cut to the
solo speech the diarizer heard inside them, so voice memory learns a
known-identity voice without waiting for a confirmation. Cluster naming matches
a diarization cluster to whoever's turns dominate it, which carries the name
onto the stretches the sensor did not see.

Sensor names sit at an origin above a voice match and below the microphone
track, so a person's own correction always wins. The sensor never sets the
diarizer's speaker count and never moves a boundary.

A cluster split evenly between two people is named for neither, a timeline
covering too little of the diarized speech names nobody, which is what
disagreeing clocks look like, and a floor nobody confirmed ends at the last
reading that saw it rather than running to the end of the call. A sensor that reports nothing leaves
naming exactly as it was before, which is by voice alone.

Named people and recurring unnamed voices share one identity store. A confirmed
speaker name can add meeting audio to a profile. Automatic recognition reads the
profiles and never trains them. Human corrections take precedence over automatic
matches.

Line corrections use positions on the meeting timeline. They remain attached to
the corrected audio when transcript assembly or speaker re-analysis changes line
and cluster identifiers.

A cluster identifier is only meaningful inside one recording. A call that dropped
and was rejoined is two recordings under one row, and both number their speakers
from zero, so every correction names the recording it belongs to.

## Reading the archive

The meetings window lists every recording, grouped by when and searched by title,
notes, speaker name, and transcript text. The transcripts are read once in the
background, so search covers titles immediately and words a moment later.

Selecting a meeting opens the same controls that used to appear only when a
meeting finished. Naming a speaker rewrites `speakers.map.json` and re-renders
`transcript.md` for the recording it belongs to.

Right-clicking a row archives it or moves it to the Trash. Archiving writes
`archivedAt` into `metadata.json` and moves the row to the Archived filter,
where it is put back from. Every file stays where it is.

Moving to the Trash asks first, then hands every folder the conversation was
recorded in to the Finder's Trash, both halves of a rejoined call included, and
drops that meeting's rows from `speaker_occurrence` so it stops counting towards
how many meetings a voice has been heard in. The confirmed voice material stays.
Putting the folders back from the Trash puts the meeting back in the list. The
meeting being recorded is refused, and a folder that will not move leaves the
recording the conversation started with in place, so its row still reaches what
is left.

An imported recording is filed under the date the recorder wrote rather than the
date the file was copied. Pipit reads the container's creation date, then a
timestamp in the filename, then the file's date on this Mac, and refuses anything
before 1990 or more than a day ahead. `metadata.json` records which of the three
it used. The manifest remains the authority on how long the audio runs.

## Browser sensor

```text
content script -> browser background -> pipit-nativehost -> Unix socket -> Pipit
```

The sensor reports provider, meeting state, URL, and audible-tab state. Native
detection continues when the extension disconnects.

Pipit accepts sensor connections only from its bundled native host when a browser
launched that host. Sensor evidence is combined with native evidence and cannot
end a recording by disappearing on its own.
