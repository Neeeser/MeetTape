#!/usr/bin/env python3
"""Write the ground truth the bench harness scores against.

Reads the AMI manual annotations, which hold one word element per spoken word
with a start time, an end time and the agent who said it, and writes one JSON
file per meeting under Benchmarks/ground-truth. No audio is read and none is
written: a case names a window on the published recording, and the harness cuts
that window itself.

    python3 scripts/build-bench-truth.py --annotations ami_public_manual_1.6.2.zip \
        --window 360 ES2002a ES2002b
    python3 scripts/build-bench-truth.py --annotations ami-annotations \
        --whole ES2008b IS1009c

The annotations source is either the published zip or a directory holding its
contents. A windowed case picks the 6-minute span where the worst-served
speaker talks most, because attribution and voice enrolment both need every
participant to say enough. A whole-meeting case scores the entire recording,
which is what exercises chunking.
"""

import argparse
import io
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Benchmarks", "ground-truth")


class Annotations:
    """The annotation tree, read from a zip or from an unpacked directory."""

    def __init__(self, path):
        self.path = path
        self.zip = zipfile.ZipFile(path) if zipfile.is_zipfile(path) else None
        self.names = set(self.zip.namelist()) if self.zip else None

    def read(self, relative):
        if self.zip is None:
            full = os.path.join(self.path, relative)
            if not os.path.exists(full):
                return None
            with open(full, "rb") as handle:
                return handle.read()
        if relative not in self.names:
            return None
        return self.zip.read(relative)


def participants(annotations, meeting):
    """agent letter -> global AMI speaker id, from corpusResources/meetings.xml."""
    raw = annotations.read("corpusResources/meetings.xml")
    if raw is None:
        raise SystemExit("no corpusResources/meetings.xml in the annotations")
    text = raw.decode("latin-1")
    for block in re.findall(r"(<meeting\b[^>]*>.*?</meeting>)", text, re.S):
        if re.search(r'observation="%s"' % meeting, block):
            return dict(
                re.findall(r'agent="([A-E])"[^>]*global_name="([^"]+)"', block)
            )
    raise SystemExit("no participant record for %s" % meeting)


def words(annotations, meeting, agent):
    raw = annotations.read("words/%s.%s.words.xml" % (meeting, agent))
    if raw is None:
        return []
    tree = ET.parse(io.BytesIO(raw))
    out = []
    for node in tree.getroot():
        if not node.tag.endswith("w"):
            continue  # vocalsound, gap and disfluency markers are not words
        if node.get("punc") == "true":
            continue
        start, end = node.get("starttime"), node.get("endtime")
        if start is None or end is None or not (node.text or "").strip():
            continue
        out.append({
            "start": float(start),
            "end": float(end),
            "text": node.text.strip(),
            "agent": agent,
            "truncated": node.get("trunc") == "true",
        })
    return out


def speech_seconds(word_list, agent, gap=0.5):
    spans = []
    for word in sorted((w for w in word_list if w["agent"] == agent), key=lambda w: w["start"]):
        if spans and word["start"] - spans[-1][1] <= gap:
            spans[-1][1] = max(spans[-1][1], word["end"])
        else:
            spans.append([word["start"], word["end"]])
    return sum(end - start for start, end in spans)


def best_window(all_words, length):
    """The window holding the most speakers, and among those the fairest one.

    The worst-served speaker decides between equally populous windows, because
    attribution and voice enrolment both need every participant to say enough
    and a window one person dominates measures neither. Speaker count comes
    first: some meetings have no six minutes in which all four people talk, and
    a three-speaker window beats a four-speaker one that does not exist.
    """
    horizon = max(w["end"] for w in all_words)
    best, best_rank = 0.0, (-1, -1.0)
    start = 0.0
    while start + length <= horizon:
        inside = [w for w in all_words if w["start"] >= start and w["end"] <= start + length]
        present = sorted(set(w["agent"] for w in inside))
        if present:
            rank = (len(present), min(speech_seconds(inside, a) for a in present))
            if rank > best_rank:
                best, best_rank = start, rank
        start += 15.0
    if best_rank[0] < 0:
        raise SystemExit("no window holds any speech")
    return best


def turns(word_list, gap=0.5):
    """Reference speaker turns for DER: consecutive words of one speaker."""
    out = []
    for word in sorted(word_list, key=lambda w: (w["speaker"], w["start"])):
        if out and out[-1]["speaker"] == word["speaker"] and word["start"] - out[-1]["end"] <= gap:
            out[-1]["end"] = max(out[-1]["end"], word["end"])
        else:
            out.append({"speaker": word["speaker"], "start": word["start"], "end": word["end"]})
    return sorted(out, key=lambda t: t["start"])


def build(annotations, meeting, window):
    people = participants(annotations, meeting)
    collected = []
    for agent in sorted(people):
        collected.extend(words(annotations, meeting, agent))
    if not collected:
        raise SystemExit("no word annotations for %s" % meeting)
    collected.sort(key=lambda w: w["start"])

    # A meeting shorter than the window is scored whole. ES2005a runs 306 s of
    # annotated speech, so a 360 s excerpt of it does not exist.
    if window and max(w["end"] for w in collected) <= window:
        window = None

    if window:
        start = best_window(collected, window)
        inside = [w for w in collected if w["start"] >= start and w["end"] <= start + window]
        seconds = window
    else:
        start = 0.0
        inside = collected
        seconds = round(max(w["end"] for w in collected) + 0.5, 2)
    present = sorted(set(w["agent"] for w in inside))

    reference = [{
        "start": round(w["start"] - start, 2),
        "end": round(w["end"] - start, 2),
        "text": w["text"],
        "speaker": people[w["agent"]],
        "agent": w["agent"],
        "truncated": w["truncated"],
    } for w in inside]

    truth = {
        "meeting": meeting,
        "source": "%s.Mix-Headset.wav" % meeting,
        "windowSeconds": seconds,
        "speakers": sorted(set(people[a] for a in present)),
        "agentToSpeaker": people,
        "words": reference,
        "turns": turns(reference),
    }
    if window:
        truth["windowStart"] = round(start, 2)

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "%s.json" % meeting)
    with open(path, "w") as handle:
        json.dump(truth, handle, separators=(",", ":"), sort_keys=True)

    per_speaker = {}
    for word in reference:
        per_speaker[word["speaker"]] = per_speaker.get(word["speaker"], 0) + 1
    kind = "window %.0f-%.0fs" % (start, start + seconds) if window else "whole %.0fs" % seconds
    print("%-8s %-22s words %5d  %s  (%d kB)" % (
        meeting, kind, len(reference), per_speaker, os.path.getsize(path) // 1024))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("meetings", nargs="+")
    parser.add_argument("--annotations", required=True, help="the published zip or an unpacked copy")
    parser.add_argument("--window", type=float, default=360.0)
    parser.add_argument("--whole", action="store_true", help="score the whole meeting")
    args = parser.parse_args()
    annotations = Annotations(args.annotations)
    for meeting in args.meetings:
        build(annotations, meeting, None if args.whole else args.window)


if __name__ == "__main__":
    main()
