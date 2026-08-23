#!/usr/bin/env python3
"""Write the ground truth the bench harness scores against.

Reads a meeting corpus's manual annotations, which hold one word element per
spoken word with a start time, an end time and the agent who said it, and
writes one JSON file per meeting under Benchmarks/ground-truth. No audio is
read and none is written: a case names a window on the published recording, and
the harness cuts that window itself.

    python3 scripts/build-bench-truth.py --annotations ami_public_manual_1.6.2.zip \
        --window 360 ES2002a ES2002b
    python3 scripts/build-bench-truth.py --annotations ami-annotations \
        --whole ES2008b IS1009c
    python3 scripts/build-bench-truth.py --annotations ami_public_manual_1.6.2.zip \
        --overlap-rank 6 --all --exclude-suite ami-core
    python3 scripts/build-bench-truth.py --corpus icsi \
        --annotations ICSI_core_NXT.zip --overlap-rank 4 --all

The annotations source is either the published zip or a directory holding its
contents. Two corpora are read by two readers behind one interface: AMI's NITE
words files and ICSI's, which differ in how a word is marked and in where the
agent-to-speaker mapping lives.

Window selection has two modes. The default picks the span where the
worst-served speaker talks most, because attribution and voice enrolment both
need every participant to say enough. `--overlap-rank N` instead picks the span
with the most overlapping speech and keeps the N meetings whose best window
overlaps most, which is what puts diarization under load. Every truth file
records the `overlapRatio` of the span it scores either way.
"""

import argparse
import bisect
import io
import json
import os
import re
import xml.etree.ElementTree as ET
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Benchmarks", "ground-truth")
MANIFEST = os.path.join(ROOT, "Benchmarks", "manifest.json")

STRIDE = 15.0


class Annotations:
    """The annotation tree, read from a zip or from an unpacked directory."""

    def __init__(self, path, prefix=""):
        self.path = path
        self.prefix = prefix
        self.zip = zipfile.ZipFile(path) if zipfile.is_zipfile(path) else None
        self.names = set(self.zip.namelist()) if self.zip else None

    def read(self, relative):
        relative = self.prefix + relative
        if self.zip is None:
            full = os.path.join(self.path, relative)
            if not os.path.exists(full):
                return None
            with open(full, "rb") as handle:
                return handle.read()
        if relative not in self.names:
            return None
        return self.zip.read(relative)

    def listing(self, directory):
        """The file names directly under a directory of the tree."""
        directory = self.prefix + directory.rstrip("/") + "/"
        if self.zip is None:
            full = os.path.join(self.path, directory)
            return sorted(os.listdir(full)) if os.path.isdir(full) else []
        out = set()
        for name in self.names:
            if name.startswith(directory):
                tail = name[len(directory):]
                if tail and "/" not in tail:
                    out.add(tail)
        return sorted(out)


class AmiReader:
    """The AMI manual annotations: one words file per meeting and agent."""

    name = "ami"
    source_suffix = ".Mix-Headset.wav"
    prefix = ""

    def __init__(self, annotations):
        self.annotations = annotations

    def meetings(self):
        found = set()
        for name in self.annotations.listing("words"):
            match = re.match(r"([A-Za-z0-9]+)\.[A-E]\.words\.xml$", name)
            if match:
                found.add(match.group(1))
        return sorted(found)

    def participants(self, meeting):
        """agent letter -> global AMI speaker id, from corpusResources/meetings.xml."""
        raw = self.annotations.read("corpusResources/meetings.xml")
        if raw is None:
            raise SystemExit("no corpusResources/meetings.xml in the annotations")
        text = raw.decode("latin-1")
        for block in re.findall(r"(<meeting\b[^>]*>.*?</meeting>)", text, re.S):
            if re.search(r'observation="%s"' % meeting, block):
                return dict(
                    re.findall(r'agent="([A-E])"[^>]*global_name="([^"]+)"', block)
                )
        raise SystemExit("no participant record for %s" % meeting)

    def words(self, meeting, agent):
        raw = self.annotations.read("words/%s.%s.words.xml" % (meeting, agent))
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


class IcsiReader:
    """The ICSI core NXT annotations.

    Three differences from AMI decide the code. A word carries its class in `c`
    rather than a `punc` flag, so punctuation, symbols and quote marks are
    dropped by class and `TRUNCW` is the truncation marker. The clitics AMI
    keeps inside a word ("it's", "we're") are separate elements here, so an
    element whose text opens with an apostrophe is joined back onto the word
    before it: the scorer keeps apostrophes, and a stray "'s" token is a
    substitution against every hypothesis. And a word may carry one alignment
    bound or none, so a missing start takes an even share of the gap after the
    last timed word, capped at half a second, and a missing end runs to the next
    start under the same cap. That keeps the text in the reference without
    inventing speech across a silence.
    """

    name = "icsi"
    source_suffix = ".interaction.wav"
    prefix = "ICSI/"

    WORD_CLASSES = {"W", "LET", "ABBR", "TRUNCW", "APOSS"}
    MAX_INTERPOLATED = 0.5

    def __init__(self, annotations):
        self.annotations = annotations

    def meetings(self):
        found = set()
        for name in self.annotations.listing("Words"):
            match = re.match(r"([A-Za-z0-9]+)\.[A-J]\.words\.xml$", name)
            if match:
                found.add(match.group(1))
        return sorted(found)

    def agents(self, meeting):
        found = set()
        for name in self.annotations.listing("Words"):
            match = re.match(r"%s\.([A-J])\.words\.xml$" % re.escape(meeting), name)
            if match:
                found.add(match.group(1))
        return sorted(found)

    def participants(self, meeting):
        """agent letter -> ICSI speaker tag, from that agent's segments file.

        ICSI has no meetings.xml: the speaker a channel belongs to is the
        `participant` attribute the segments carry, and it is constant within a
        file.
        """
        people = {}
        for agent in self.agents(meeting):
            raw = self.annotations.read("Segments/%s.%s.segs.xml" % (meeting, agent))
            if raw is None:
                continue
            tags = re.findall(r'participant="([^"]+)"', raw.decode("latin-1"))
            if tags:
                people[agent] = tags[0]
        if not people:
            raise SystemExit("no participant record for %s" % meeting)
        return people

    def words(self, meeting, agent):
        raw = self.annotations.read("Words/%s.%s.words.xml" % (meeting, agent))
        if raw is None:
            return []
        tree = ET.parse(io.BytesIO(raw))
        out = []
        for node in tree.getroot():
            if not node.tag.endswith("w"):
                continue  # disfmarker, vocalsound, pause and comment are not words
            text = (node.text or "").strip()
            if not text:
                continue
            kind = node.get("c") or "W"
            if kind not in self.WORD_CLASSES:
                continue
            start, end = node.get("starttime"), node.get("endtime")
            start = float(start) if start else None
            end = float(end) if end else None
            if text.startswith("'") and out:
                out[-1]["text"] += text
                if end is not None:
                    out[-1]["end"] = end
                if out[-1]["start"] is None:
                    out[-1]["start"] = start
                continue
            out.append({
                "start": start,
                "end": end,
                "text": text,
                "agent": agent,
                "truncated": kind == "TRUNCW",
            })
        return self._interpolate(out)

    def _interpolate(self, word_list):
        """Give every partly timed word a span between the words either side."""
        index = 0
        while index < len(word_list):
            if word_list[index]["start"] is not None:
                index += 1
                continue
            run = index
            while run < len(word_list) and word_list[run]["start"] is None:
                run += 1
            before = word_list[index - 1]["end"] if index > 0 else None
            if before is None and index > 0:
                before = word_list[index - 1]["start"]
            after = word_list[run]["start"] if run < len(word_list) else None
            anchor = before if before is not None else after
            if anchor is None:  # a file with no alignment at all has no reference
                return []
            count = run - index
            room = 0.0 if before is None or after is None else max(after - before, 0.0)
            each = min(room / count, self.MAX_INTERPOLATED)
            for offset in range(count):
                word_list[index + offset]["start"] = anchor + each * offset
            index = run
        for position, word in enumerate(word_list):
            if word["end"] is not None and word["end"] >= word["start"]:
                continue
            following = word_list[position + 1]["start"] if position + 1 < len(word_list) else None
            limit = word["start"] + self.MAX_INTERPOLATED
            if following is not None:
                limit = min(limit, max(following, word["start"]))
            word["end"] = limit
        return word_list


READERS = {"ami": AmiReader, "icsi": IcsiReader}


def merged(word_list, gap=0.0):
    """The spans a speaker holds the floor for, one list per agent."""
    per_agent = {}
    for word in word_list:
        per_agent.setdefault(word["agent"], []).append(word)
    out = {}
    for agent, words in per_agent.items():
        spans = []
        for word in sorted(words, key=lambda w: w["start"]):
            if spans and word["start"] - spans[-1][1] <= gap:
                spans[-1][1] = max(spans[-1][1], word["end"])
            else:
                spans.append([word["start"], word["end"]])
        out[agent] = spans
    return out


def speech_seconds(word_list, agent, gap=0.5):
    spans = merged([w for w in word_list if w["agent"] == agent], gap=gap)
    return sum(end - start for start, end in spans.get(agent, []))


def speech_profile(word_list):
    """Seconds of speech, and of that how many carry two or more voices.

    The spans come from the word timings without bridging the gaps between
    words, because bridging invents simultaneity that the recording does not
    hold. A moment two people share counts once in each number.
    """
    events = []
    for spans in merged(word_list).values():
        for start, end in spans:
            if end > start:
                events.append((start, 1))
                events.append((end, -1))
    if not events:
        return 0.0, 0.0
    events.sort()
    speech, overlapped = 0.0, 0.0
    depth, previous = 0, events[0][0]
    for moment, delta in events:
        if depth >= 1:
            speech += moment - previous
        if depth >= 2:
            overlapped += moment - previous
        depth += delta
        previous = moment
    return speech, overlapped


def overlap_ratio(word_list):
    """Fraction of speech time where two or more people talk at once."""
    speech, overlapped = speech_profile(word_list)
    return overlapped / speech if speech > 0 else 0.0


def inside(sorted_words, starts, start, length):
    """The words wholly inside a window, from a list sorted by start time."""
    first = bisect.bisect_left(starts, start)
    last = bisect.bisect_right(starts, start + length)
    return [w for w in sorted_words[first:last] if w["end"] <= start + length]


def best_window(all_words, length):
    """The window holding the most speakers, and among those the fairest one.

    The worst-served speaker decides between equally populous windows, because
    attribution and voice enrolment both need every participant to say enough
    and a window one person dominates measures neither. Speaker count comes
    first: some meetings have no six minutes in which all four people talk, and
    a three-speaker window beats a four-speaker one that does not exist.
    """
    horizon = max(w["end"] for w in all_words)
    starts = [w["start"] for w in all_words]
    best, best_rank = 0.0, (-1, -1.0)
    start = 0.0
    while start + length <= horizon:
        within = inside(all_words, starts, start, length)
        present = sorted(set(w["agent"] for w in within))
        if present:
            rank = (len(present), min(speech_seconds(within, a) for a in present))
            if rank > best_rank:
                best, best_rank = start, rank
        start += STRIDE
    if best_rank[0] < 0:
        raise SystemExit("no window holds any speech")
    return best


def most_overlapped_window(all_words, length, min_speakers, floor=5.0, min_density=0.5):
    """The window with the most simultaneous speech, or None if none qualifies.

    Two gates come before the ratio. A window must hold `min_speakers` voices
    with at least `floor` seconds each, because two people talking over each
    other for six minutes tests nothing about counting speakers and somebody
    who says one word in six minutes is not a speaker any diarizer can be asked
    to find. And speech must fill `min_density` of the window: the ratio divides
    by speech time, so silence is free, and the densest windows by that measure
    alone were ICSI's digit-reading sections, where the participants read
    numbers aloud over each other and a quarter of the span is speech. Words
    from below either gate stay in the reference: they were spoken, and dropping
    them would make the transcript score them as insertions.
    """
    horizon = max(w["end"] for w in all_words)
    starts = [w["start"] for w in all_words]
    best, best_ratio, best_speakers, best_density = None, -1.0, 0, 0.0
    start = 0.0
    while start + length <= horizon:
        within = inside(all_words, starts, start, length)
        present = set(
            agent for agent in set(w["agent"] for w in within)
            if speech_seconds(within, agent) >= floor
        )
        if len(present) >= min_speakers:
            speech, overlapped = speech_profile(within)
            ratio = overlapped / speech if speech > 0 else 0.0
            if speech / length >= min_density and ratio > best_ratio:
                best, best_ratio = start, ratio
                best_speakers, best_density = len(present), speech / length
        start += STRIDE
    if best is None:
        return None
    return {
        "start": best, "ratio": best_ratio,
        "speakers": best_speakers, "density": best_density,
    }


def turns(word_list, gap=0.5):
    """Reference speaker turns for DER: consecutive words of one speaker."""
    out = []
    for word in sorted(word_list, key=lambda w: (w["speaker"], w["start"])):
        if out and out[-1]["speaker"] == word["speaker"] and word["start"] - out[-1]["end"] <= gap:
            out[-1]["end"] = max(out[-1]["end"], word["end"])
        else:
            out.append({"speaker": word["speaker"], "start": word["start"], "end": word["end"]})
    return sorted(out, key=lambda t: t["start"])


def collect(reader, meeting):
    people = reader.participants(meeting)
    collected = []
    for agent in sorted(people):
        collected.extend(reader.words(meeting, agent))
    if not collected:
        raise SystemExit("no word annotations for %s" % meeting)
    collected.sort(key=lambda w: w["start"])
    return people, collected


def build(reader, meeting, window, start=None, people=None, collected=None):
    if people is None or collected is None:
        people, collected = collect(reader, meeting)

    # A meeting shorter than the window is scored whole. ES2005a runs 306 s of
    # annotated speech, so a 360 s excerpt of it does not exist.
    if window and max(w["end"] for w in collected) <= window:
        window = None

    if window:
        if start is None:
            start = best_window(collected, window)
        starts = [w["start"] for w in collected]
        within = inside(collected, starts, start, window)
        seconds = window
    else:
        start = 0.0
        within = collected
        seconds = round(max(w["end"] for w in collected) + 0.5, 2)
    present = sorted(set(w["agent"] for w in within))

    reference = [{
        "start": round(w["start"] - start, 2),
        "end": round(w["end"] - start, 2),
        "text": w["text"],
        "speaker": people[w["agent"]],
        "agent": w["agent"],
        "truncated": w["truncated"],
    } for w in within]

    ratio = overlap_ratio([
        {"start": w["start"], "end": w["end"], "agent": w["agent"]} for w in within
    ])
    truth = {
        "meeting": meeting,
        "source": "%s%s" % (meeting, reader.source_suffix),
        "windowSeconds": seconds,
        "overlapRatio": round(ratio, 4),
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
    print("%-8s %-22s overlap %5.1f%%  words %5d  %s  (%d kB)" % (
        meeting, kind, ratio * 100, len(reference), per_speaker,
        os.path.getsize(path) // 1024))


def rank_by_overlap(reader, meetings, window, min_speakers, min_density, keep):
    """Score every meeting's most overlapped window and build the top `keep`."""
    ranked = []
    for meeting in meetings:
        try:
            people, collected = collect(reader, meeting)
        except SystemExit as failure:
            print("%-8s skipped: %s" % (meeting, failure))
            continue
        if max(w["end"] for w in collected) <= window:
            print("%-8s skipped: shorter than the window" % meeting)
            continue
        found = most_overlapped_window(
            collected, window, min_speakers, min_density=min_density
        )
        if found is None:
            print("%-8s skipped: no window holds %d voices densely enough" % (
                meeting, min_speakers))
            continue
        ranked.append((found["ratio"], meeting, found, people, collected))
        print("%-8s overlap %5.1f%%  at %6.0fs  %d voices  speech %4.0f%%" % (
            meeting, found["ratio"] * 100, found["start"], found["speakers"],
            found["density"] * 100))
    ranked.sort(key=lambda row: (-row[0], row[1]))
    print("")
    chosen = ranked[:keep]
    for _, meeting, found, people, collected in chosen:
        build(reader, meeting, window, start=found["start"],
              people=people, collected=collected)
    return [meeting for _, meeting, _, _, _ in chosen]


def suite_roster(name):
    with open(MANIFEST) as handle:
        manifest = json.load(handle)
    if name not in manifest["suites"]:
        raise SystemExit("no suite named %s in the manifest" % name)
    return manifest["suites"][name]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("meetings", nargs="*")
    parser.add_argument("--annotations", required=True, help="the published zip or an unpacked copy")
    parser.add_argument("--corpus", choices=sorted(READERS), default="ami")
    parser.add_argument("--window", type=float, default=360.0)
    parser.add_argument("--whole", action="store_true", help="score the whole meeting")
    parser.add_argument("--all", action="store_true", help="every meeting in the archive")
    parser.add_argument("--exclude-suite", action="append", default=[],
                        help="leave out the meetings a committed suite already runs")
    parser.add_argument("--overlap-rank", type=int, metavar="N",
                        help="keep the N meetings whose best window overlaps most")
    parser.add_argument("--min-speakers", type=int, default=4,
                        help="voices a window must hold to be ranked (default 4)")
    parser.add_argument("--min-density", type=float, default=0.5,
                        help="share of a ranked window that must be speech (default 0.5)")
    args = parser.parse_args()

    reader_class = READERS[args.corpus]
    annotations = Annotations(args.annotations, prefix=reader_class.prefix)
    reader = reader_class(annotations)

    meetings = list(args.meetings)
    if args.all:
        meetings.extend(m for m in reader.meetings() if m not in meetings)
    for suite in args.exclude_suite:
        already = set(suite_roster(suite))
        meetings = [m for m in meetings if m not in already]
    if not meetings:
        raise SystemExit("no meetings to build")

    if args.overlap_rank:
        chosen = rank_by_overlap(
            reader, meetings, args.window, args.min_speakers, args.min_density,
            args.overlap_rank
        )
        print("")
        print("suite roster: %s" % json.dumps(chosen))
        return
    for meeting in meetings:
        build(reader, meeting, None if args.whole else args.window)


if __name__ == "__main__":
    main()
