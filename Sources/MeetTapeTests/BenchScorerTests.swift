import Foundation
import MeetTapeBench
import TestKit

/// Controls on the meter itself.
///
/// A benchmark number is only worth reading if the scorer is known to be right,
/// so three transcripts with known answers are put through it: the reference
/// itself, the reference with one word in ten deleted, and the reference with
/// its speaker labels shuffled. The first two pin word error rate to an exact
/// value; the third pins attribution and DER to chance, which is what a
/// diarizer that has learned nothing scores.
enum BenchScorerTests {
    /// The committed truth for one AMI excerpt, which is text and already in
    /// the tree for the harness to score against.
    static func truth() throws -> BenchTruth {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MeetTapeTests
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()
        return try BenchTruth.read(
            from: repository.appendingPathComponent("Benchmarks/ground-truth/ES2002b.json")
        )
    }

    /// The transcript a perfect system would produce: one line per reference
    /// turn, holding that turn's words, on that turn's speaker.
    static func oracle(_ truth: BenchTruth) -> [BenchUtterance] {
        var bySpeaker: [String: [BenchTruth.Word]] = [:]
        for word in truth.words { bySpeaker[word.speaker, default: []].append(word) }
        for key in bySpeaker.keys { bySpeaker[key]?.sort { $0.start < $1.start } }
        return truth.turns.sorted { $0.start < $1.start }.map { turn in
            let inside = (bySpeaker[turn.speaker] ?? []).filter {
                $0.start >= turn.start - 0.001 && $0.end <= turn.end + 0.001
            }
            return BenchUtterance(
                start: turn.start, end: turn.end,
                text: inside.map(\.text).joined(separator: " "),
                speakerKey: turn.speaker
            )
        }
    }

    /// Deterministic, because a control that draws differently every run is not
    /// a control. Any fixed sequence does; this is the smallest one.
    struct FixedSequence {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next(upTo bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static var suite: Suite {
        Suite("BenchScorer", [
            test("the reference scored against itself is a perfect transcript") { expect in
                let truth = try truth()
                let score = BenchScorer.score(truth: truth, utterances: oracle(truth))
                expect.close(score.wer, 0, tolerance: 0.0001, "an oracle transcript has no errors")
                expect.close(score.attribution, 1.0, tolerance: 0.001)
                expect.close(try expect.unwrap(score.der), 0, tolerance: 0.0001)
                expect.equal(score.repeatedNgrams, 0)
                expect.equal(score.hypothesisSpeakers, truth.speakers.count)
            },

            test("deleting one word in ten costs ten points of word error rate") { expect in
                let truth = try truth()
                var kept = 0
                let thinned = oracle(truth).map { utterance -> BenchUtterance in
                    var words: [String] = []
                    for word in utterance.text.split(separator: " ") {
                        kept += 1
                        if kept % 10 != 0 { words.append(String(word)) }
                    }
                    var copy = utterance
                    copy.text = words.joined(separator: " ")
                    return copy
                }
                let score = BenchScorer.score(truth: truth, utterances: thinned)
                expect.close(
                    score.wer, 0.101, tolerance: 0.005,
                    "one word in ten deleted is a tenth of the reference, got \(score.wer)"
                )
                expect.equal(
                    score.insertions, 0, "deleting words cannot produce an insertion"
                )
            },

            test("shuffled speaker labels score at chance") { expect in
                let truth = try truth()
                var sequence = FixedSequence()
                let speakers = truth.speakers
                let shuffled = oracle(truth).map { utterance -> BenchUtterance in
                    var copy = utterance
                    copy.speakerKey = speakers[sequence.next(upTo: speakers.count)]
                    return copy
                }
                let score = BenchScorer.score(truth: truth, utterances: shuffled)
                // The words are untouched, so only the labels are being measured.
                expect.close(score.wer, 0, tolerance: 0.0001)
                // The optimal cluster mapping lifts a random assignment above
                // the one-in-four a coin toss suggests, and the Python
                // reference measured 49% attribution and 46.5% DER on this
                // excerpt. A real run scores 99% and 8%, so the band is wide
                // and still tells the two apart.
                expect.isTrue(
                    score.attribution > 0.30 && score.attribution < 0.65,
                    "random labels scored \(score.attribution) attribution"
                )
                let der = try expect.unwrap(score.der)
                expect.isTrue(der > 0.25 && der < 0.70, "random labels scored \(der) DER")
            },
        ])
    }
}
