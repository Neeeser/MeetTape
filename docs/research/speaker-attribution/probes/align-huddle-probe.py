#!/usr/bin/env python3
"""Aligns the huddle accessibility log against the room recording.

The tree log says when Slack decided somebody is speaking. The recording says
when they actually started. Subtracting the two gives the attack and the release
of `p-huddle_peer_tile__overlay--active_speaker`, which is what decides whether
the signal can bound an utterance or only name a turn.

    ./align-huddle-probe.py /tmp/huddle-run

Clocks are pinned by the beep the runner plays into the room. Its position in
the recording and the epoch it was issued at give the offset between the two
streams, to within afplay's own startup latency of roughly 100 ms.
"""

import math
import re
import struct
import sys
import wave
from pathlib import Path

HOP = 0.02          # 20 ms frames
BEEP_HZ = 1000.0
MIN_SPEECH = 0.30   # ignore anything shorter than this
MIN_GAP = 0.40      # bridge pauses shorter than this inside one turn


def frames(path):
    with wave.open(str(path)) as w:
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
    samples = struct.unpack(f'<{len(raw) // 2}h', raw)
    step = int(rate * HOP)
    out = []
    for i in range(0, len(samples) - step, step):
        block = samples[i:i + step]
        rms = math.sqrt(sum(v * v for v in block) / len(block))
        # Goertzel at the beep frequency, to tell the sync tone from speech.
        coeff = 2 * math.cos(2 * math.pi * BEEP_HZ / rate)
        s1 = s2 = 0.0
        for v in block:
            s0 = v + coeff * s1 - s2
            s2, s1 = s1, s0
        tone = math.sqrt(max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0)) / len(block)
        out.append((i / rate, rms, tone))
    return rate, out


def find_beep(rows):
    """The sync tone is the frame where 1 kHz energy dominates by the most."""
    best, best_score = None, 0
    for t, rms, tone in rows:
        if rms < 500:
            continue
        score = tone / (rms + 1e-9)
        if score > best_score:
            best, best_score = t, score
    return best, best_score


def segments(rows, beep_at):
    quiet = sorted(r[1] for r in rows)
    floor = quiet[len(quiet) // 10] if quiet else 0
    threshold = max(floor * 4, 120)
    on = []
    for t, rms, _ in rows:
        # The sync tone is not speech.
        if beep_at is not None and abs(t - beep_at) < 0.4:
            continue
        if rms > threshold:
            on.append(t)
    if not on:
        return [], threshold, floor
    spans, start, last = [], on[0], on[0]
    for t in on[1:]:
        if t - last > MIN_GAP:
            spans.append((start, last + HOP))
            start = t
        last = t
    spans.append((start, last + HOP))
    return [s for s in spans if s[1] - s[0] >= MIN_SPEECH], threshold, floor


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/huddle-run')
    watch_epoch = float((out / 'watch_epoch.txt').read_text().strip())
    beep_epoch = float((out / 'beep_epoch.txt').read_text().strip())

    rate, rows = frames(out / 'mic.wav')
    beep_at, score = find_beep(rows)
    if beep_at is None:
        # macOS voice processing cancels the machine's own playback out of the
        # captured microphone, so the sync tone often never reaches the file.
        # Only the attack needs it. The release survives without it.
        shift = None
        print('no sync tone in the recording, so attack is not measurable here')
    else:
        shift = (beep_epoch - watch_epoch) - beep_at
        print(f'sync tone at {beep_at:.2f}s in the recording (confidence {score:.3f})')
        print(f'recording clock sits {shift:+.3f}s from the watcher clock')
    print()

    spans, threshold, floor = segments(rows, beep_at)
    print(f'noise floor {floor:.0f}, speech threshold {threshold:.0f}')
    label = 'on the watcher clock' if shift is not None else 'on the recording clock'
    print(f'{len(spans)} speech spans, {label}:')
    for a, b in spans:
        off = shift or 0
        print(f'  speech  {a + off:7.2f} -> {b + off:7.2f}   ({b - a:.2f}s)')

    events = []
    for line in (out / 'watch.log').read_text().splitlines():
        m = re.match(r'\s*([\d.]+)\s+(.+?)\s{2,}speaking=(\w+) muted=(\w+)', line)
        if m:
            events.append((float(m.group(1)), m.group(2).strip(),
                           m.group(3) == 'true', m.group(4)))
    print(f'\n{len(events)} tree transitions:')
    for t, who, speaking, muted in events:
        print(f'  tree    {t:7.2f}   {who:<22} speaking={speaking} muted={muted}')

    report(spans, events, shift)


def windows(events):
    """Speaking windows per tile, as (who, rose_at, fell_at)."""
    open_at, out = {}, []
    for t, who, speaking, _ in events:
        if speaking and who not in open_at:
            open_at[who] = t
        elif not speaking and who in open_at:
            out.append((who, open_at.pop(who), t))
    return out


def report(spans, events, shift):
    wins = windows(events)
    print(f'\n{len(wins)} speaking windows:')
    for who, rose, fell in wins:
        print(f'  {who:<24} {rose:7.2f} -> {fell:7.2f}   ({fell - rose:.2f}s)')

    # Release without cross-stream alignment. Both ends of a speaking window come
    # from the same log, and the burst length comes from the recording alone, so
    # a constant offset between the two clocks cancels out.
    #
    # A window runs from (speech start + attack) to (speech end + release), so
    # window minus burst is release minus attack. Attack is small and positive,
    # which makes this a lower bound on the release.
    print('\nrelease, from window length minus burst length:')
    if len(spans) != len(wins):
        print(f'  {len(spans)} bursts against {len(wins)} windows, pairing by order anyway')
    for i, (who, rose, fell) in enumerate(wins):
        if i >= len(spans):
            break
        burst = spans[i][1] - spans[i][0]
        print(f'  {who:<24} window {fell - rose:5.2f}s  burst {burst:5.2f}s'
              f'  -> release >= {fell - rose - burst:5.2f}s')

    if shift is not None:
        print('\nattack, needs the sync tone and is only as good as it:')
        for a, b in spans:
            a += shift
            rise = next((w for w in wins if w[1] >= a - 1.5), None)
            if rise:
                print(f'  speech at {a:7.2f}  ->  tile rose at {rise[1]:7.2f}'
                      f'   attack {rise[1] - a:+5.2f}s')


if __name__ == '__main__':
    main()
