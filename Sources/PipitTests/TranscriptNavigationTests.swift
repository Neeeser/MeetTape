import Foundation
import PipitCore
import TestKit

/// Walking a transcript: to one speaker's turns from their chip, and through
/// the places a word appears from Command-F.
enum TranscriptNavigationTests {
    private static func line(speaker: String, start: Double, text: String) -> CombinedLine {
        TranscriptGroupingTests.line(speaker: speaker, start: start, text: text)
    }

    private static func blocks() -> [CombinedLineBlock] {
        CombinedLineBlock.blocks(from: [
            line(speaker: "Andrew", start: 0, text: "You talking about the demo tomorrow?"),
            line(speaker: "Chris Latimer", start: 3, text: "Yeah, the one you said you wanted."),
            line(speaker: "Speaker 3", start: 6, text: "Sorry, can everyone hear me?"),
            line(speaker: "Andrew", start: 9, text: "Did you see the email from McKinsey?"),
            line(speaker: "Andrew", start: 12, text: "He is a product manager at McKinsey. McKinsey runs Lily."),
            line(speaker: "Speaker 3", start: 15, text: "Yes, loud and clear."),
        ])
    }

    static var suite: Suite {
        Suite("TranscriptNavigation", [
            test("a speaker walk lands on their first turn and steps through the rest, wrapping") { expect in
                let all = blocks()
                var walk = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-a", in: all)
                expect.equal(walk.targets.count, 2, "two turns, six seconds between them")
                expect.equal(walk.current?.blockID, all[2].id, "the first turn, not the chip's order")
                expect.equal(walk.counter, "1 of 2")
                expect.equal(walk.label, "Speaker 3")
                walk.next()
                expect.equal(walk.current?.blockID, all[4].id, "the last block, after Andrew's merged turn")
                walk.next()
                expect.equal(walk.current?.blockID, all[2].id, "the last turn is followed by the first")
                walk.previous()
                expect.equal(walk.counter, "2 of 2")
            },

            test("a name from another recording is not this recording's speaker") { expect in
                let walk = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-b", in: blocks())
                expect.equal(walk.targets, [], "Speaker 3 in the other half is somebody else")
                expect.equal(walk.counter, "0 of 0")
                expect.isNil(walk.current)
            },

            test("a search counts every occurrence, case-insensitively, in reading order") { expect in
                let all = blocks()
                // The question and the answer are consecutive Andrew lines, so
                // the grouping shows them as one block with three matches.
                let walk = TranscriptNavigation.find("mckinsey", in: all)
                expect.equal(all.count, 5)
                expect.equal(walk.targets.count, 3, "one in the question, two in the answer")
                expect.equal(walk.targets.map(\.blockID), [all[3].id, all[3].id, all[3].id])
                expect.equal(walk.counter, "1 of 3")
                expect.isTrue(walk.isSearch)
                expect.isTrue(
                    walk.targets[0].location < walk.targets[1].location
                        && walk.targets[1].location < walk.targets[2].location,
                    "in reading order inside the paragraph"
                )
                // The block's own matches, for tinting, and which is current.
                let inBlock = walk.matches(in: all[3].id)
                expect.equal(inBlock.all.count, 3)
                expect.equal(inBlock.current?.length, 8)
                expect.equal(walk.matches(in: all[2].id).all, [], "nothing to tint elsewhere")
            },

            test("a blank search finds nothing rather than everything") { expect in
                expect.equal(TranscriptNavigation.find("   ", in: blocks()).targets, [])
                expect.equal(TranscriptNavigation.find("", in: blocks()).targets, [])
            },

            test("a walk survives a correction and keeps its place where it still exists") { expect in
                let all = blocks()
                var walk = TranscriptNavigation.find("McKinsey", in: all)
                walk.next()
                walk.next()
                expect.equal(walk.counter, "3 of 3")
                // The answer is reassigned to Chris, so it is a different block
                // with the same words in it.
                var lines = all.flatMap(\.lines)
                lines[4].speakerName = "Chris Latimer"
                let refreshed = walk.refreshed(in: CombinedLineBlock.blocks(from: lines))
                expect.equal(refreshed.targets.count, 3)
                expect.equal(refreshed.counter, "1 of 3", "the old place is gone, so it starts over")

                let named = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-a", in: all)
                expect.equal(named.refreshed(in: all), named, "nothing changed, nothing moves")
            },
        ])
    }
}
