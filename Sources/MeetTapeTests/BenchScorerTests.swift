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

    /// A score holding only the fields a baseline rule reads. Decoded rather
    /// than built, because the memberwise initialiser is internal to the bench
    /// module.
    static func score(werNoFiller: Double, attribution: Double, repeats: Int) throws -> BenchScore {
        let json = """
            {"meeting":"ES2002b","wer":\(werNoFiller),"werNoFiller":\(werNoFiller),
             "substitutions":0,"insertions":0,"deletions":0,"referenceWords":100,
             "hypothesisWords":100,"utterances":10,"attribution":\(attribution),
             "attributionMerged":\(attribution),"attributionOfLabelled":\(attribution),
             "attributionScored":100,"overlapExcluded":0,"referenceSpeakers":4,
             "hypothesisSpeakers":4,"speakerKeys":[],"clusterMapping":{},
             "repeatedNgrams":\(repeats),"repeatedShare":0,"overlappingPairs":0,
             "worstOverlapSeconds":0}
            """
        return try JSONDecoder().decode(BenchScore.self, from: Data(json.utf8))
    }

    /// The transcript a perfect system would produce: one line per reference
    /// turn, holding that turn's words, under an opaque cluster key.
    ///
    /// The keys are `c0`...`c3` rather than the reference names, so the scorer
    /// has the permutation to solve that a real diarizer hands it.
    static func oracle(_ truth: BenchTruth) -> [BenchUtterance] {
        let key = Dictionary(uniqueKeysWithValues: truth.speakers.enumerated().map {
            ($0.element, "c\($0.offset)")
        })
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
                speakerKey: key[turn.speaker] ?? turn.speaker
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


    /// Four speakers with one turn each, two of them split across two clusters.
    ///
    /// Hand-computable: 200 words per speaker, and the diarizer cuts A's turn
    /// into 120 words on c0 and 80 on c4, B's into 120 on c1 and 80 on c5.
    static func splitCase() -> (truth: BenchTruth, utterances: [BenchUtterance]) {
        let speakers = ["A", "B", "C", "D"]
        var words: [BenchTruth.Word] = []
        var turns: [BenchTruth.Turn] = []
        for (index, speaker) in speakers.enumerated() {
            let base = Double(index) * 100
            turns.append(BenchTruth.Turn(speaker: speaker, start: base, end: base + 100))
            for step in 0..<200 {
                let start = base + Double(step) * 0.5
                words.append(BenchTruth.Word(
                    start: start, end: start + 0.4,
                    text: "\(speaker)\(step)", speaker: speaker, truncated: false
                ))
            }
        }
        let utterances = [
            BenchUtterance(start: 0, end: 60, text: "a", speakerKey: "c0"),
            BenchUtterance(start: 60, end: 100, text: "b", speakerKey: "c4"),
            BenchUtterance(start: 100, end: 160, text: "c", speakerKey: "c1"),
            BenchUtterance(start: 160, end: 200, text: "d", speakerKey: "c5"),
            BenchUtterance(start: 200, end: 300, text: "e", speakerKey: "c2"),
            BenchUtterance(start: 300, end: 400, text: "f", speakerKey: "c3"),
        ]
        let truth = BenchTruth(
            meeting: "split", source: "none.wav", windowStart: nil, windowSeconds: 400,
            speakers: speakers, agentToSpeaker: [:], words: words, turns: turns
        )
        return (truth, utterances)
    }

    /// Eight clusters, four speakers, ten words each: every count ties.
    static func tiesCase() -> (
        pairs: [(reference: String, hypothesis: String?)], speakers: [String], keys: [String]
    ) {
        let speakers = ["A", "B", "C", "D"]
        var pairs: [(reference: String, hypothesis: String?)] = []
        for (index, key) in (0..<8).map({ ("c\($0)") }).enumerated() {
            let speaker = speakers[index / 2]
            for _ in 0..<10 { pairs.append((speaker, key)) }
        }
        return (pairs, speakers, (0..<8).map { "c\($0)" })
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
                let keys = (0..<truth.speakers.count).map { "c\($0)" }
                let shuffled = oracle(truth).map { utterance -> BenchUtterance in
                    var copy = utterance
                    copy.speakerKey = keys[sequence.next(upTo: keys.count)]
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

            test("an over-split transcript scores strict below merged") { expect in
                // Four speakers, one turn each, 200 words each. Two of those
                // turns are cut in half by the diarizer, so six clusters cover
                // four voices and 800 words are attributed.
                let split = splitCase()
                let score = BenchScorer.score(truth: split.truth, utterances: split.utterances)
                expect.equal(score.attributionScored, 800, "every word is asked about")
                expect.equal(score.hypothesisSpeakers, 6)
                // The four clusters of the best injective mapping hold
                // 120 + 120 + 200 + 200 = 640 words.
                expect.close(score.attribution, 0.8, tolerance: 0.0001)
                // Folding c4 onto A and c5 onto B recovers the other 160.
                expect.close(score.attributionMerged, 1.0, tolerance: 0.0001)
                expect.close(score.attributionOfLabelled, 0.8, tolerance: 0.0001)
            },

            test("the greedy branch decides its ties by name") { expect in
                // Eight clusters over four speakers, ten words each, so every
                // count ties and only the tiebreakers decide the mapping.
                let ties = tiesCase()
                var seen: [BenchScorer.Mapping] = []
                for _ in 0..<8 {
                    seen.append(BenchScorer.bestMapping(
                        pairs: ties.pairs, referenceSpeakers: ties.speakers,
                        hypothesisKeys: ties.keys
                    ))
                }
                let expected = ["c0": "A", "c2": "B", "c4": "C", "c6": "D"]
                for mapping in seen {
                    expect.equal(
                        mapping.injective, expected,
                        "count desc, reference asc, hypothesis asc decides every tie"
                    )
                    expect.equal(mapping.strictCorrect, 40)
                    expect.equal(mapping.mergedCorrect, 80)
                }
            },

            test("a repeat budget ratchets down and never up") { expect in
                // The deciding run left two cases with repeats at a chunk seam.
                // Those two carry a budget so a clean sweep is green; every
                // other case still fails on a single repeated sentence.
                let baselines = BenchBaselines(entries: [
                    "parakeet/local/IS1009c": BenchBaselines.Entry(
                        wer: 0.30, werNoFiller: 0.28, attribution: 0.90, der: 0.20,
                        repeatedNgrams: 7
                    ),
                    "parakeet/local/ES2002b": BenchBaselines.Entry(
                        wer: 0.18, werNoFiller: 0.16, attribution: 0.99, der: 0.07,
                        repeatedNgrams: 0
                    ),
                ])

                let over = try score(werNoFiller: 0.28, attribution: 0.90, repeats: 8)
                expect.equal(
                    baselines.regressions(key: "parakeet/local/IS1009c", score: over),
                    ["8 repeated 8-grams against 7"],
                    "one more repeat than the budget is a regression"
                )

                let atBudget = try score(werNoFiller: 0.28, attribution: 0.90, repeats: 7)
                expect.isTrue(
                    baselines.regressions(key: "parakeet/local/IS1009c", score: atBudget).isEmpty,
                    "the recorded count itself passes"
                )

                let fewer = try score(werNoFiller: 0.28, attribution: 0.90, repeats: 0)
                expect.isTrue(
                    baselines.regressions(key: "parakeet/local/IS1009c", score: fewer).isEmpty,
                    "removing repeats is never a failure"
                )

                let zeroBudget = try score(werNoFiller: 0.16, attribution: 0.99, repeats: 1)
                expect.equal(
                    baselines.regressions(key: "parakeet/local/ES2002b", score: zeroBudget),
                    ["1 repeated 8-grams against 0"],
                    "a case recorded clean fails on a single repeat"
                )

                let unknown = try score(werNoFiller: 0.16, attribution: 0.99, repeats: 1)
                expect.equal(
                    baselines.regressions(key: "parakeet/local/IB4005", score: unknown),
                    ["1 repeated 8-grams against 0"],
                    "and so does a case with no entry at all"
                )
            },

            test("the committed baselines carry the deciding run's repeats") { expect in
                let repository = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let baselines = try BenchBaselines.read(
                    from: repository.appendingPathComponent("Benchmarks/baselines.json")
                )
                expect.equal(baselines.entries["parakeet/local/ES2002c"]?.repeatedNgrams, 1)
                expect.equal(baselines.entries["parakeet/local/IS1009c"]?.repeatedNgrams, 7)
                expect.equal(baselines.entries["parakeet/local/ES2002b"]?.repeatedNgrams, 0)
            },
        ])
    }
}
