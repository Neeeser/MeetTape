import Foundation
import PipitCore
import TestKit

/// The transcript pane groups consecutive lines by who spoke them, so one person
/// talking through five assembler splits reads as one block. Grouping is
/// display-only: every line keeps its identity and stays individually
/// correctable.
enum TranscriptGroupingTests {
    static func line(
        recording: String = "rec-a", speaker: String, start: Double, text: String
    ) -> CombinedLine {
        let utterance = Utterance(
            id: Utterance.identifier(chunkID: "c1", track: .remote, start: start, end: start + 2),
            start: start, end: start + 2, track: .remote,
            rawSpeakerLabel: "c1_speaker_00", speakerKey: "c1_speaker_00",
            text: text, chunkID: "c1", model: "test"
        )
        return CombinedLine(
            recordingID: recording, utterance: utterance, speakerName: speaker,
            timelineStart: start
        )
    }

    static var suite: Suite {
        Suite("TranscriptGrouping", [
            test("consecutive lines from one speaker form one block") { expect in
                let blocks = CombinedLineBlock.blocks(from: [
                    line(speaker: "Andrew", start: 0, text: "first"),
                    line(speaker: "Andrew", start: 3, text: "second"),
                    line(speaker: "Andrew", start: 7, text: "third"),
                ])
                expect.equal(blocks.count, 1, "one speaker, one block")
                expect.equal(blocks.first?.lines.count, 3, "all three lines kept")
                expect.equal(blocks.first?.speakerName, "Andrew", "block carries the name")
                expect.equal(
                    blocks.first?.lines.map(\.utterance.text), ["first", "second", "third"],
                    "order preserved"
                )
            },

            test("a change of speaker starts a new block") { expect in
                let blocks = CombinedLineBlock.blocks(from: [
                    line(speaker: "Andrew", start: 0, text: "a"),
                    line(speaker: "Dana", start: 3, text: "b"),
                    line(speaker: "Andrew", start: 6, text: "c"),
                ])
                expect.equal(blocks.count, 3, "interleaved speakers never merge")
                expect.equal(blocks.map(\.speakerName), ["Andrew", "Dana", "Andrew"], "one block each")
            },

            test("the same display name in two recordings stays two blocks") { expect in
                // Two halves of a dropped call each have their own diarization,
                // so "Speaker 1" on either side can be different people.
                let blocks = CombinedLineBlock.blocks(from: [
                    line(recording: "rec-a", speaker: "Speaker 1", start: 0, text: "before the drop"),
                    line(recording: "rec-b", speaker: "Speaker 1", start: 3, text: "after the rejoin"),
                ])
                expect.equal(blocks.count, 2, "names are only comparable within one recording")
            },

            test("an empty transcript groups to nothing") { expect in
                expect.equal(CombinedLineBlock.blocks(from: []).count, 0, "no lines, no blocks")
            },

            test("a block is identified by its first line") { expect in
                let first = line(speaker: "Andrew", start: 0, text: "a")
                let blocks = CombinedLineBlock.blocks(from: [
                    first, line(speaker: "Andrew", start: 3, text: "b"),
                ])
                expect.equal(blocks.first?.id, first.id, "stable identity for lazy rendering")
            },
        ])
    }
}
