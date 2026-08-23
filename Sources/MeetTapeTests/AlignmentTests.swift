import Foundation
import MeetTapeCore
import TestKit

/// CTC forced alignment: given frame log-probabilities and the known
/// transcript, recover when each word was said. This is what lets a
/// transcription model that returns no timings feed the timeline.
enum AlignmentTests {
    /// Log-probabilities where each frame strongly prefers one symbol.
    /// `peaks[t]` is the preferred vocabulary index at frame t.
    static func peaked(_ peaks: [Int], vocabularySize: Int) -> [[Float]] {
        peaks.map { peak in
            (0..<vocabularySize).map { $0 == peak ? Float(-0.01) : Float(-8.0) }
        }
    }

    static var alignmentSuite: Suite {
        Suite("ForcedAlignment", [
            test("words land on the frames that spoke them") { expect in
                // Vocabulary: 0,1,2 are tokens, 3 is blank. "ab" = [0,1], "c" = [2].
                let logProbs = peaked([0, 0, 3, 1, 3, 2, 2, 3, 3], vocabularySize: 4)
                let words = try expect.unwrap(CtcForcedAlignment.align(
                    logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                    words: [
                        CtcForcedAlignment.TokenizedWord(text: "ab", tokens: [0, 1]),
                        CtcForcedAlignment.TokenizedWord(text: "c", tokens: [2]),
                    ]
                ))
                expect.equal(words.map(\.text), ["ab", "c"])
                expect.close(words[0].start, 0.0, tolerance: 0.001)
                expect.close(words[0].end, 0.4, tolerance: 0.001, "token 1 ends after frame 3")
                expect.close(words[1].start, 0.5, tolerance: 0.001)
                expect.close(words[1].end, 0.7, tolerance: 0.001, "token 2 held frames 5 and 6")
            },

            test("a repeated token forces a blank between occurrences") { expect in
                // "aa" as [0, 0] needs blank-separated occurrences: 0, blank, 0.
                let logProbs = peaked([0, 3, 0, 3], vocabularySize: 4)
                let words = try expect.unwrap(CtcForcedAlignment.align(
                    logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                    words: [CtcForcedAlignment.TokenizedWord(text: "aa", tokens: [0, 0])]
                ))
                expect.close(words[0].start, 0.0, tolerance: 0.001)
                expect.close(words[0].end, 0.3, tolerance: 0.001)
            },

            test("too few frames for the transcript refuses instead of inventing") { expect in
                let logProbs = peaked([0], vocabularySize: 4)
                expect.isNil(
                    CtcForcedAlignment.align(
                        logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                        words: [CtcForcedAlignment.TokenizedWord(text: "abc", tokens: [0, 1, 2])]
                    ),
                    "one frame cannot carry three tokens"
                )
            },

            test("an oversized trellis refuses instead of exhausting memory") { expect in
                let logProbs = peaked(Array(repeating: 0, count: 50), vocabularySize: 4)
                expect.isNil(
                    CtcForcedAlignment.align(
                        logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                        words: [CtcForcedAlignment.TokenizedWord(text: "a", tokens: [0])],
                        maximumCells: 100
                    ),
                    "the caller falls back to chunk-level timing instead"
                )
            },

            test("empty input aligns to nothing") { expect in
                expect.equal(
                    CtcForcedAlignment.align(
                        logProbs: peaked([3, 3], vocabularySize: 4), frameDuration: 0.1,
                        blankId: 3, words: []
                    )?.count, 0, "no words is a valid, empty alignment"
                )
            },
        ])
    }

    static var groupingSuite: Suite {
        Suite("AlignedSegments", [
            test("a pause starts a new segment") { expect in
                let words = [
                    CtcForcedAlignment.AlignedWord(text: "hello", start: 0.0, end: 0.4),
                    CtcForcedAlignment.AlignedWord(text: "there", start: 0.5, end: 0.9),
                    CtcForcedAlignment.AlignedWord(text: "general", start: 3.0, end: 3.6),
                ]
                let segments = CtcForcedAlignment.segments(
                    from: words, pauseSeconds: 1.0, maximumSeconds: 30
                )
                expect.equal(segments.count, 2)
                expect.equal(segments.first?.text, "hello there")
                expect.equal(segments.first?.words?.count, 2)
                expect.close(segments.last?.start ?? 0, 3.0, tolerance: 0.001)
            },

            test("a monologue splits at the duration cap") { expect in
                let words = (0..<40).map {
                    CtcForcedAlignment.AlignedWord(
                        text: "w\($0)", start: Double($0), end: Double($0) + 0.5
                    )
                }
                let segments = CtcForcedAlignment.segments(
                    from: words, pauseSeconds: 1.0, maximumSeconds: 10
                )
                expect.isTrue(segments.count > 1, "40 seconds of speech never stays one segment")
                expect.isTrue(
                    segments.allSatisfy { ($0.end - $0.start) <= 10.5 },
                    "every segment respects the cap"
                )
                expect.equal(
                    segments.flatMap { $0.words ?? [] }.count, 40,
                    "no word is lost to the splitting"
                )
            },
        ])
    }

    static var all: [Suite] { [alignmentSuite, groupingSuite] }
}
