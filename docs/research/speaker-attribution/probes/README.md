# Probes

Four throwaway tools for answering the open questions in `../FINDINGS.md`. None
of them are part of the app and none of them record audio.

Accessibility permission belongs to the terminal that runs the Swift ones, not to
the binaries.

## Slack huddle

`huddlewatch.swift` is the one to run now. It reads the roster, the mute state,
and the speaking class, and prints a line whenever one of them changes.

```sh
xcrun swiftc -O huddlewatch.swift -o /tmp/huddlewatch && /tmp/huddlewatch 120
```

`p-huddle_peer_tile__overlay--active_speaker` is known to hold for over eight
seconds past the end of speech and then clear. What is left to measure is the
release time and the handover, so run it in a huddle with two people. Take turns
speaking for a few seconds each with a long gap between turns, then talk over
each other, and read the timestamps.

`axdump.swift` and `axwatch.swift` are the general tools that found this. Use
them on a part of the UI nobody has mapped yet. `axdump` prints one tree,
`axwatch` diffs it on an interval so anything that changes in time with speech
stands out.

```sh
xcrun swiftc -O axdump.swift -o /tmp/axdump && xcrun swiftc -O axwatch.swift -o /tmp/axwatch
AXFULL=1 /tmp/axdump com.tinyspeck.slackmacgap 40 200000 > /tmp/baseline.txt
/tmp/axwatch com.tinyspeck.slackmacgap --interval 0.2 --seconds 120 > /tmp/watch.log
```

## Google Meet and Zoom web

Open the meeting link and stop on the prejoin screen. Open the console, paste
`browser-probe.js`, and check it prints `RTCPeerConnection hooked in top`. The
hook replaces the constructor, so a connection the page has already opened cannot
be reached, and pasting after joining loses the WebRTC half.

Two things that bite:

- Firefox refuses console pastes until you type `allow pasting` and press return.
  Do that first, on the prejoin screen, before the call starts.
- Zoom runs its client in a `#webclient` iframe with its own window object. The
  probe sweeps for frames every 250 ms and hooks each one as it appears, so you
  should see a second `hooked in iframe#webclient` line. If you only ever see
  `top`, the frame arrived cross-origin and the Zoom half will come back empty.

Get the file onto the clipboard rather than selecting it by hand:

```sh
pbcopy < browser-probe.js
```

Join. While the call runs, call `__pipitProbe.mark('name')` each time someone
starts talking, so the log has ground truth in it.

Afterwards:

```js
__pipitProbe.report()   // tables: audio sources, changed attributes, roster
__pipitProbe.save()     // downloads the raw log as JSON
```

An empty audio-source table on Zoom means the client is in WebAssembly mode and
there are no WebRTC audio tracks to read.

To measure how far each signal lags the audio, record the same call with Pipit
and cross-correlate the probe timestamps against the energy envelope of the
remote track.
