# Speaker attribution from the meeting client

Research pass on reading who is in a call, who unmutes, and who is talking when,
from Google Meet, Zoom, and Slack, using the browser extension and macOS
accessibility. Measured on 2026-08-25 against Slack 4.x and Firefox 143 on this
Mac. Nothing here is implemented yet.

## What the app does today

Diarization produces clusters, `SpeakerAlignment` attributes words to clusters,
and a person names the clusters afterwards. Two pieces of plumbing for sensor
speaker data already exist and carry nothing:

- `BrowserMeetingEvent` has `participants: [String]?` and
  `activeSpeaker: String?`. `PipitNativeHost/main.swift:140` parses both off the
  wire. Nothing downstream reads either one.
- `provider.js` `buildState()` accepts a `participants` argument. `content.js`
  never passes one.

`SlackAccessibilityReader` walks Slack's tree for two strings, "leave huddle" and
"mute microphone". Its doc comment says participant names and the active speaker
are not available from Slack on macOS. A live huddle showed both are available,
so that comment is wrong and should be retired.

## Measured on this machine

Probe source is in `probes/`. `axdump.swift` walks one app's accessibility tree.
`axwatch.swift` diffs the tree on an interval so a speaking indicator shows up as
whatever node flips in time with speech. `browser-probe.js` runs in a meeting tab
and records WebRTC audio levels, DOM attribute changes, and caption text on one
clock.

**Slack exposes its whole Chromium accessibility tree, including CSS classes.**
The app tree is 708 nodes and a full walk takes 370 ms. Setting
`AXManualAccessibility` on the application element is what builds the web tree.
Every node carries `AXDOMClassList` and `ChromeAXNodeId`. Slack's class names are
semantic, for example:

```
AXButton | desc=Start huddle in general
    · AXDOMClassList = c-button--focus-visible,c-button-unstyled,c-icon_button,
      c-icon_button--size_medium,p-huddle_channel_header_button__start_button
    · ChromeAXNodeId = 234588
```

That matters because a React app renders a speaking ring as a modifier class, and
`AXDOMClassList` hands the class list over. The existing reader throws it away
because it only reads `AXDescription` and `AXTitle`.

### Probed in a live huddle

Run on 2026-08-25 in a one-person huddle, with `axwatch` diffing the tree at
5 Hz while the microphone was toggled and speech happened. Everything the doc
comment says is unavailable turned out to be there.

A tile identifies its person and its session. Own tile against someone else's:

```
huddle-grid-gridcell-self_U01SELFUSER
huddle-grid-gridcell-3f9c1a20-0000-4000-8000-abcdefabcdef_U02OTHERUSR
```

The user id follows the last underscore in both. The prefix is the session, so
one person joined from two devices is two tiles carrying one id, and `self_`
marks the local user without having to ask who that is.

Everything the speaking flag does, it does on **other people's tiles**, not only
on your own. In a two-person huddle every speaking transition landed on the
remote tile, and that tile's mute state changed four times and was readable each
time. This is the case that matters. The local user is already deterministic from
the microphone track, and the remote track is the mixed stream that needs
splitting.

A huddle tile looks like this:

```
AXCell   desc=View Ada Lovelace's profile
         domid=huddle-grid-gridcell-self_U03SOLOUSER
         class=p-huddle_peer_tile
         ChromeAXNodeId=246230
  AXButton  desc=video is off, audio is on
            class=p-huddle_peer_tile__name_overlay,
                  p-huddle_peer_tile__name_overlay--unmuted
  AXGroup   class=p-huddle_peer_tile__activity_icons_container
  AXGroup   domid=…-a11y_huddle_peer_tile_description  class=offscreen
    AXStaticText  value=Audio
```

So one walk gives four things per person:

- **Slack user id**, from the tile's `AXDOMIdentifier`. `U03SOLOUSER` is
  workspace-unique and stable across meetings, which is a far better identity key
  than a display name.
- **Display name**, from the tile description.
- **Mute state**, twice over. The description flips between "audio is on" and
  "audio is off", the name overlay gains and loses
  `p-huddle_peer_tile__name_overlay--unmuted`, and the offscreen description text
  changes from "Audio" to "Audio, Muted".
- **Speaking**, from a class that appears and disappears:
  `p-huddle_peer_tile__overlay--active_speaker`, on a
  `p-huddle_peer_tile__mic_overlay` node that only exists while it is set.

Muting cleared the speaking class in the same 200 ms tick that changed the mute
description, so the two are consistent.

`probes/huddlewatch.swift` reads all four and prints changes. It resolves the
roster in one traversal and then polls only the tile subtrees, which is what a
real reader would do.

`--active_speaker` is a hold with a release, not a latch on whoever last held the
floor. Re-reading a huddle that was still open and still unmuted, the class was
gone and the `p-huddle_peer_tile__mic_overlay` node it lives on did not exist at
all.

That distinction decides what the signal can say. A latch can only ever name a
person, so it could never represent silence. A release means "nobody is talking"
is a state the timeline can carry, which is what makes it fusable with
diarization rather than only a naming hint.

**The release is about 1.5 seconds.** Measured from single short words with long
silences around them, in a two-person huddle with the phone as the far end. A
0.52 s burst produced a 1.77 s speaking window, which puts the release at 1.25 s
plus whatever the attack is. Isolated windows for one word ran 1.39 s, 2.02 s and
1.77 s. An earlier reading of "more than eight seconds" was a long utterance
misread as a long hold, and it is wrong.

The measurement needs no clock alignment between the recording and the tree,
which matters because the alignment does not work. Both ends of a speaking window
come from the same log and the burst length comes from the recording alone, so a
constant offset between the two cancels. Attack is not measurable this way and no
number is claimed for it.

macOS voice processing is why. Slack holds the microphone with echo cancellation
on, so the machine's own playback is stripped out of anything else capturing that
device. The sync tone the runner plays never reaches the recording, and neither
does the far end coming out of the speakers. Only the speaker's own voice in the
room survives, faintly. This is the same effect already recorded for capture, now
seen from the other side.

**At most one tile is marked at a time.** With both ends unmuted in one room, both
microphones carried the same voice. Per-person voice activity would light both
tiles. Instead the flag swapped, atomically, inside a single 50 ms poll:

```
 3.565  self (…525)     speaking=false
 3.565  Ada L        speaking=true
 9.807  Ada L        speaking=true
 9.807  self (…525)     speaking=false
16.567  self (…525)     speaking=true
16.567  Ada L        speaking=false
```

So this is a dominant-speaker flag, and overlapping speech is invisible to it.
Handover costs nothing though. No gap, no window where two tiles are both set,
no window where the floor is unowned mid-transfer.

What that leaves is a turn timeline. It names who holds the floor, to about a
second and a half, one person at a time. It does not bound an utterance and it
cannot see two people at once, so the diarizer keeps owning boundaries and
overlap, and this names the turns it finds.

One implementation note from the log. The tree re-parents tiles under a different
window subtree as the grid re-renders, so index paths break. Key on
`AXDOMIdentifier` or `ChromeAXNodeId` and re-resolve when a read comes back
empty.

**Firefox exposes web page content the same way.** A full walk of Firefox is 941
nodes and includes `AXWebArea`, ARIA landmarks, headings, and `AXDOMIdentifier`
per node. So a Meet or Zoom page is readable through accessibility with no
extension at all. Two costs come with that. Only the foreground tab has a built
tree, and reading it turns Firefox's accessibility engine on for the rest of the
session, which slows the browser. The extension path avoids both.

**Google Meet is not reachable from the in-app browser.** `meet.google.com`
redirects to the marketing page when signed out, and signing in is not something
I do. Everything below about Meet and Zoom page structure comes from published
sources and needs the live probe to confirm.

## Signals, per platform

### Google Meet in Firefox

Four signals, strongest first.

**0. What a live Meet actually negotiates.** Read off a real two-person call on
2026-08-25, from a second signed-in client driven over CDP. The published
architecture holds exactly.

The remote description carries three audio m-lines with fixed SSRCs:

```
m=audio ...  a=ssrc:6666 cname:6666
m=audio ...  a=ssrc:6667 cname:6667
m=audio ...
a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
```

Three points follow. The SSRC is a slot, not a person, which is why identity has
to come from CSRC. `ssrc-audio-level` is negotiated on every audio m-line, so
per-packet levels are on the wire and available in principle. And the connected
peer connection carried four audio receivers with exactly one unmuted, which is
the SFU parking the current speaker in one slot and idling the rest.

The DOM names participants in Google's own resource format:

```
data-participant-id="spaces/EXAMPLESPACE/devices/406"
```

That is per-device and structured, so it is the Meet-side identity key, the
counterpart to Slack's user id. Remote mute state is reachable too, though only
indirectly. The control reading `Mute Ada Lovelace's microphone` exists while
that person is unmuted, and no tile carries an aria-label for it.

Two mechanics for anyone wiring this up. The hook has to be installed before any
page script runs. Meet captures its own reference to `RTCPeerConnection` when its
bundle loads, and a hook injected at the prejoin screen sees nothing, which shows
up as zero peer connections. Playwright's `addInitScript` plus a reload fixes it.
Chrome also populates the source APIs off the decoded audio path, so a receiver
whose track is not being consumed reports nothing.

**The DOM carries a per-participant audio level meter, and it is fast.** Found by
diffing attribute changes against the remote audio envelope on one clock, in a
two-person call on 2026-08-26. One signature stood out and nothing else came
close:

```
div jsname=QgSmzd @class     40 changes, 85% during remote speech
next best candidate                              19%
```

It is not a boolean. The class cycles through an idle state and three ascending
level buckets, several times a second, while someone talks:

```
31.06s  lvl=0.1698   gjg47c -> HX2H7     near=Andrew
31.16s  lvl=0.1698   HX2H7  -> Oaajhc    near=Andrew
31.47s  lvl=0.1698   Oaajhc -> wEsLMd    near=Andrew
31.67s  lvl=0.1959   wEsLMd -> gjg47c    near=Andrew
```

`gjg47c` is idle and `HX2H7`, `Oaajhc` and `wEsLMd` climb. Remote speech started
at 31.01 s and the meter moved at 31.06 s, so the **attack is 50 ms**. Release was
not measured, because the probe kept only its first 40 samples of the 286 changes
and all of them fell inside the first burst.

The meters are per participant. Of 40 samples, 34 sat inside the speaking
participant's tile and the rest belonged to a separate meter under Audio
settings, which is the local input. So each person owns a meter and each meter
moves on its own.

That is a different class of signal from Slack's. Slack gives one exclusive
boolean released about 1.5 s late. Meet gives a graded level per person that
reacts in 50 ms, which is fast enough to bound an utterance rather than only name
a turn.

**Whether Meet can mark two people at once is untested.** The structure says yes,
because meters are per tile, but a two-person call cannot show it. Only one audio
slot ever carried sound. With three virtual slots and one remote participant,
`slot1` peaked at 0.196 while `slot2` and `slot3` sat at exactly 0.0000 for the
whole run. Answering this needs three people talking over each other.

**Reaching the audio without a peer connection.** Meet plays its slots through
media elements, so `document.querySelectorAll('audio,video')` and `srcObject`
give one track per slot and an envelope per slot. That is what produced the
numbers above. It yields no CSRC, because there is no route from a track back to
its receiver.

**Firefox cannot be patched from a console, permanently.**
`RTCPeerConnection.prototype.getStats` is `writable: false, configurable: false`,
so assigning to it fails silently and no prototype wrapper is possible. Only the
constructor is replaceable, and by the time a console runs, Meet holds its own
reference. This is a testing limit rather than a product one. A content script at
`document_start` replaces the constructor before Meet loads, which is how the
Chrome run reached two live peer connections.

**Whether `getContributingSources()` actually returns CSRCs on Meet is still
open.** It returned empty for the whole session, but that proves nothing, because
no audio ever reached the observing client. `totalSamplesReceived` stayed at 0
against a `totalSamplesDuration` of 558 s while `packetsReceived` climbed past
19,000. Packets arrived and no samples were decoded from them. The far end was
confirmed live and unmuted the whole time. Meet did not route that audio to the
second client, and the reason was not established. Finish this from a client that
demonstrably receives audio, which means running `browser-probe.js` in the
browser already in the call rather than joining a second observer.

**1. WebRTC contributing sources.** Meet's SFU multiplexes participants onto three
audio transceivers, and the Meet Media API documentation states the rule plainly:
"Meet assigns each participant in a conference their own unique CSRC when they
join", and that CSRC holds until they leave. In the page,
`RTCRtpReceiver.getContributingSources()` returns one object per CSRC seen in the
last ten seconds, each with `source`, `audioLevel` (0.0 to 1.0), `timestamp`, and
`rtpTimestamp`. `getSynchronizationSources()` adds `voiceActivityFlag`. Both have
been baseline in Firefox and Chrome since 2019.

That is a per-person speaking timeline at packet rate, keyed by a stable
per-conference identifier, taken from the same data Meet's own UI draws from. It
is not scraping and it does not depend on captions being on.

Two things it does not give. The CSRC is a number, not a name. And it only covers
the three loudest at any moment, which is fine for attribution because the people
it drops are the ones who are silent.

Getting the name means binding CSRC to a person once per call. The DOM says
"Priya is speaking" at roughly UI cadence, the CSRC stream says "12345 is loud"
at packet cadence, and a few seconds of overlap fixes the binding for the rest of
the session. After that the DOM is only a cross-check.

The catch is reach. A content script runs in an isolated world and cannot see the
page's `RTCPeerConnection` calls. The hook has to run in the page world before
Meet opens its connections. Firefox MV2 supports this through
`window.wrappedJSObject` and `exportFunction`, or by injecting a script element at
`document_start`.

**2. Participant panel and tile state in the DOM.** Names come from the People
panel and from tile labels. The speaking indicator is a class or attribute that
toggles. Meet's class names rotate, so the probe finds it by diffing attribute
changes rather than by a hardcoded selector.

**3. Captions.** Meet's caption region carries the speaker name as a sibling node
of the caption text, which is how the open-source `transcriptonic` extension reads
it (`TRANSCRIPT_REGION: 'div[role="region"][tabindex="0"]'`, then
`mutationTargetElement.previousSibling.textContent` for the name). Accurate
attribution, but it needs the user to turn captions on, and Meet rewrites earlier
blocks as it corrects itself.

**4. Meet REST API, after the fact.** `conferenceRecords.transcripts.entries` gives
`participant`, `text`, `startTime`, and `endTime` per utterance, and
`conferenceRecords.participants` gives the roster with session times. This is
Google's own ground truth. It needs a Workspace account with transcription turned
on for the meeting, so it is a bonus path, not the mechanism.

The Meet **Media** API is a different thing and is not usable here. Developer
Preview only, and every participant in the conference has to be enrolled in the
preview program.

### Zoom web client in Firefox

**Confirmed WASM on this account**, probed 2026-08-26 on `app.zoom.us/wc/...`. The
probe hooked both the top window and the `iframe#webclient`, and neither produced
a single audio tap. No media element carried a track and no peer connection ever
appeared. So there is nothing to tap and no per-person level, on this account, in
this browser.

A 98 second run with two people produced nine attribute signatures, and all nine
were chrome: the local mute button flipping between `mute my microphone` and
`unmute my microphone`, footer visibility, and theme classes. No participant
tile, no roster, no speaking indicator, with the observer attached to both the
top document and the `iframe#webclient` document.

The likely reason is that the WASM client draws video into a canvas, so the
active-speaker highlight is painted pixels rather than a DOM attribute. Nothing
in the run contradicts that. What Zoom reliably gives is the local mute state.
Roster and per-person mute exist only while the participants panel is open, which
was not tested, and an active speaker may not be readable at all.

Treat Zoom as roster-and-mute at best until a run with the participants panel
open says otherwise. It is the weakest of the three by a wide margin and should
be the last thing built.

One incidental note for the extension. The client lives at `app.zoom.us`, and the
joined URL carries the passcode in its query string. `provider.js` already trims
a URL to origin and path before anything is relayed, which is exactly right and
must stay that way.

Weaker across the board, and the reason is architectural. Zoom's web client does
not send media over WebRTC tracks. It moves audio and video over WebRTC data
channels and codes them in WebAssembly. Newer builds can negotiate full WebRTC
depending on device, so which mode a given call uses has to be read at runtime.
In WASM mode `getContributingSources()` returns nothing and the strongest Meet
signal is simply absent.

What is left:

- The client runs inside a same-origin `#webclient` iframe, so the extension has
  to reach `contentDocument` or inject with `all_frames: true`. The current
  manifest has `all_frames: false` and matches only `https://*.zoom.us/*`.
- The participants panel gives the roster and per-person mute state.
- Live transcription gives text, but the caption line carries no name. It carries
  an avatar image, and `transcriptonic` recovers a name by matching the avatar
  `src` against video tiles and caching the result in `localStorage`. That is
  fragile enough that it falls back to "Person <hash>".
- The active-speaker highlight on the tile grid is the practical speaking signal,
  and it only marks one person at a time.

Realistic outcome for Zoom web: a reliable roster and mute state, a
one-speaker-at-a-time timeline of moderate accuracy, and no per-person audio
levels. Zoom's native app is not installed on this Mac, so it is out of scope
until it is.

### Slack huddles

No extension reaches Slack, so this is accessibility only. It is the strongest of
the three platforms anyway, and it needs no new permission, because the app
already holds accessibility and already walks this tree.

The live huddle above settled it. One traversal gives a roster keyed by Slack
user id, a display name, a mute state, and a speaking flag, all as
accessibility-tree strings. Slack's own accessibility changelog says huddle
captions carry the speaker name too, which would add words to the timeline, and
that is untested.

The user id is the part worth dwelling on. `U03SOLOUSER` is workspace-unique and
stable across every meeting, so it is a real identity key. A display name is not:
two people share one, and one person changes theirs. Nothing else in this
research produces an identifier of that quality. Meet's CSRC is stable for one
conference and then gone.

Three mechanics matter for making the read cheap and correct. A 708-node poll
costs 370 ms, which is too much at speaking cadence, so the reader resolves tiles
once and then polls only the tile subtrees, as `huddlewatch.swift` does. Element
references die when the grid re-renders, so tiles key on `AXDOMIdentifier` and
get re-resolved when a read comes back empty. And the huddle now opens in a mini
window that docks into a bottom bar, so the subtree the reader scopes to is not
always a top-level `AXWindow`.

What `--active_speaker` gives is a turn timeline. One person at a time, released
about 1.5 s after they stop, and clearing to nobody when the room goes quiet. It
does not bound an utterance and it cannot represent two people talking at once,
so the diarizer still owns boundaries and overlap.

## What the probes have to settle

Each of these is a yes or no that changes the design, and none can be answered
without a live call.

| Question | Probe |
| --- | --- |
| Do Slack huddle captions carry the speaker name into the tree? | `huddlewatch` with captions on |
| What is the attack, and does it need a loopback device to measure? | a capture that voice processing does not strip |
| Does `getContributingSources()` return CSRCs on a real Meet call? | `browser-probe.js` in the browser already in the call, never a second observer |
| How many CSRCs appear against how many people are in the call? | same |
| What is the release on Meet's level meter? | rerun now that the probe keeps a timestamp per change |
| Can Meet mark two people speaking at once, which Slack cannot? | three people talking over each other, one meter per tile |
| How far does each signal lag the recorded audio? | run Pipit at the same time, cross-correlate the probe log against the energy envelope |

That last one decides whether the sensor timeline can be used for alignment at
all, or only for naming. A UI indicator with attack and release smoothing can sit
200 ms or more behind the audio, and it is a per-platform constant we would have
to measure and subtract.

## How this would fuse with diarization

Not as a replacement. Three levels, each usable on its own, and each one an
improvement over the level below.

**Naming only.** Take the roster and the speaking timeline, match each diarization
cluster to whichever participant was speaking during that cluster's intervals,
and write the name. Diarization still decides the boundaries. Wrong sensor data
produces a wrong name, which the user already fixes today, so this cannot make
anything worse than it is now.

**Count constraint.** Feed the number of people who actually unmuted and spoke to
the diarizer as its cluster count. This is where the accuracy win is largest,
because over-clustering and under-clustering are what diarization gets wrong, and
the roster answers the question the clusterer is guessing at.

Slack already supplies every input this needs. The roster is exact, remote mute
state is readable and was seen changing four times in one run, and the turn
timeline says which of those people ever took the floor. A person who sat muted
for an hour is not a cluster, and a person who held the floor four times is at
least one. Note what the count must be built from. The number of tiles is the
room, not the speaker count, and only the turn timeline separates the two.

**Forced assignment.** Where the sensor timeline is confident and unambiguous,
assign words to people directly and let diarization fill the rest. Only worth
doing for Meet, where CSRC audio levels are precise enough to trust against the
audio.

Two constraints on all three.

The remote track is one mixed stream. Meet and Zoom mix every far-end participant
into the audio the process tap captures, so the sensor timeline is the only
deterministic way to split it. The microphone track is already deterministic and
does not need any of this.

Clocks have to be reconciled. Sensor events are wall clock, the audio timeline is
relative to recording start, and a long call drifts. The alignment needs an offset
per meeting, a per-platform latency constant, and a way to detect that the
correlation has fallen apart rather than silently mislabelling an hour of audio.

## Where it plugs into the existing code

The model already has the shapes.

- A sensor speaking timeline is a `DiarizationRun` with a backend string like
  `sensor-meet-csrc`. `RawDiarization` already keeps one active run per track and
  retains superseded runs, so a sensor run and a model run can coexist and either
  can be made active.
- A sensor-derived name is a `SpeakerAssignment` with a new
  `SpeakerAssignmentOrigin` case. It ranks above `voiceProfile` and below
  `human`, so a person's correction always wins and re-running recognition never
  overwrites it.
- The extension already carries `participants` and `activeSpeaker` to the app.
  Filling them in `content.js` and reading them in the runtime is the smallest
  version of this that does anything.
- Slack needs `SlackAccessibilityReader` to read `AXDOMClassList` and the huddle
  subtree, which is a change in what the existing walk collects, not a new
  subsystem.

One project rule bites here and needs deciding early. Cluster identifiers only
mean something inside one recording, and the speaker strip must be able to draw
every voice the meetings list counts. A sensor-named speaker with no cluster
behind it would be a name the strip cannot draw. So sensor names attach to
clusters, and a participant who never got matched to a cluster is roster
information, not a speaker.

## Risks

- Every DOM signal breaks without warning when the vendor ships a redesign. The
  rule the extension already follows applies here too. A broken sensor means
  unnamed speakers, never a missed or corrupted recording.
- Reading a page's accessibility tree through Firefox turns the accessibility
  engine on and slows the browser. Prefer the extension wherever it reaches.
- Patching `RTCPeerConnection` in the page world is more invasive than anything
  the extension does today. It reads audio levels and never touches media, but it
  is a real escalation in what the extension is allowed to do and should be
  visible to the user.
- Participant names are personal data. The project already keeps voice profiles
  out of meeting folders and meeting content out of logs. A roster is the same
  class of thing and needs the same treatment.

## Sources

- [RTCRtpReceiver.getContributingSources](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpReceiver/getContributingSources)
- [RTCRtpReceiver.getSynchronizationSources](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpReceiver/getSynchronizationSources)
- [Meet Media API overview](https://developers.google.com/workspace/meet/media-api/guides/overview)
- [Manage virtual media streams in Meet Media API](https://developers.google.com/workspace/meet/media-api/guides/virtual-streams)
- [conferenceRecords.transcripts.entries](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts.entries)
- [transcriptonic](https://github.com/vivek-nexus/transcriptonic), read at commit `d9be648`, 2026-08-04
- [How Zoom's web client avoids using WebRTC](https://webrtchacks.com/zoom-avoids-using-webrtc/)
- [A technical guide to the Zoom Web SDK](https://www.daily.co/blog/zoom-web-sdk-technical-notes/)
- [Slack accessibility changelog](https://slack.com/help/articles/50668520513939-Accessibility-changelog)
