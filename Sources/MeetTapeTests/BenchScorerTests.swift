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
    static func score(
        werNoFiller: Double, attribution: Double, repeats: Int, tcpWer: Double? = nil
    ) throws -> BenchScore {
        let json = """
            {"meeting":"ES2002b","wer":\(werNoFiller),"werNoFiller":\(werNoFiller),
             \(tcpWer.map { "\"tcpWer\":\($0)," } ?? "")
             "substitutions":0,"insertions":0,"deletions":0,"referenceWords":100,
             "hypothesisWords":100,"utterances":10,"attribution":\(attribution),
             "attributionMerged":\(attribution),"attributionOfLabelled":\(attribution),
             "attributionScored":100,"overlapExcluded":0,"referenceSpeakers":4,
             "hypothesisSpeakers":4,"speakerKeys":[],"clusterMapping":{},
             "repeatedNgrams":\(repeats),"repeatedShare":0,"overlappingPairs":0,
             "worstOverlapSeconds":0,"werConversational":\(werNoFiller),
             "orderingFloorWer":0,"attributionCoverage":1,
             "speechCoverage":0.9,"wordsPerMinute":150}
            """
        return try JSONDecoder().decode(BenchScore.self, from: Data(json.utf8))
    }

    /// One run of a case, with the fields the deciding aggregation touches and
    /// two it must leave alone: `deletions` counts a particular transcript and
    /// `clusterMapping` describes a particular set of clusters.
    static func run(
        wer: Double, attribution: Double, der: Double?, repeats: Int, deletions: Int
    ) throws -> BenchScore {
        let json = """
            {"meeting":"ES2002b","wer":\(wer),"werNoFiller":\(wer / 2),
             "werConversational":\(wer / 4),"orderingFloorWer":0.1,
             "substitutions":0,"insertions":0,"deletions":\(deletions),
             "referenceWords":100,"hypothesisWords":100,"utterances":10,
             "attribution":\(attribution),"attributionMerged":\(attribution + 0.05),
             "attributionOfLabelled":\(attribution + 0.02),"attributionScored":100,
             "overlapExcluded":0,"attributionCoverage":1,"referenceSpeakers":4,
             "hypothesisSpeakers":4,"speakerKeys":["c\(deletions)"],
             "clusterMapping":{"c\(deletions)":"A"},"repeatedNgrams":\(repeats),
             "repeatedShare":0,"overlappingPairs":0,"worstOverlapSeconds":0,
             \(der.map { "\"der\":\($0),\"derStrict\":\($0 + 0.1)," } ?? "")
             "speechCoverage":0.9,"wordsPerMinute":150}
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

    /// A truth built from turns, each holding evenly spaced one-second words.
    static func made(
        _ turns: [(speaker: String, start: Double, words: [String])], seconds: Double
    ) -> BenchTruth {
        var words: [BenchTruth.Word] = []
        var spans: [BenchTruth.Turn] = []
        for turn in turns {
            for (step, text) in turn.words.enumerated() {
                let start = turn.start + Double(step)
                words.append(BenchTruth.Word(
                    start: start, end: start + 0.5, text: text,
                    speaker: turn.speaker, truncated: false
                ))
            }
            spans.append(BenchTruth.Turn(
                speaker: turn.speaker, start: turn.start,
                end: turn.start + Double(turn.words.count)
            ))
        }
        return BenchTruth(
            meeting: "made", source: "none.wav", windowStart: nil, windowSeconds: seconds,
            speakers: Array(Set(turns.map(\.speaker))).sorted(), agentToSpeaker: [:],
            words: words, turns: spans
        )
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

            test("interleaved speech costs an oracle transcript word order") { expect in
                // One long turn with a backchannel dropped into the middle of
                // it. Read by turn the reference ends "five yeah"; read by the
                // clock the "yeah" falls between "four" and "five", so a
                // transcript that gets every word right still pays two edits,
                // which the DP takes as two substitutions over that pair.
                let interleaved = made([
                    ("A", 0, ["one", "two", "three", "four", "five"]),
                    ("B", 3.5, ["yeah"]),
                ], seconds: 10)
                expect.close(
                    BenchScorer.orderingFloor(interleaved), 2.0 / 6.0, tolerance: 0.0001,
                    "one interleaved word costs two edits out of six words"
                )

                let sequential = made([
                    ("A", 0, ["one", "two", "three"]),
                    ("B", 4, ["four", "five", "six"]),
                    ("A", 8, ["seven", "eight"]),
                ], seconds: 12)
                expect.close(
                    BenchScorer.orderingFloor(sequential), 0, tolerance: 0.0001,
                    "turns that do not interleave read the same both ways"
                )

                // The floor comes off wer and never takes it below zero.
                let score = BenchScorer.score(
                    truth: sequential,
                    utterances: [BenchUtterance(
                        start: 0, end: 12, text: "one two three four five six seven eight",
                        speakerKey: "c0"
                    )]
                )
                expect.close(score.orderingFloorWer, 0, tolerance: 0.0001)
                expect.close(score.netOfFloorWer, score.wer, tolerance: 0.0001)
            },

            test("an oracle transcript scores zero per-speaker word error") { expect in
                let truth = try truth()
                let score = BenchScorer.score(truth: truth, utterances: oracle(truth))
                expect.close(
                    try expect.unwrap(score.cpWer), 0, tolerance: 0.0001,
                    "every speaker's words are present on some key, so the best assignment is exact"
                )
            },

            test("words on the wrong speaker are charged on both speakers' streams") { expect in
                // A and B speak four words each; the transcript holds all eight
                // words, all on one key. Serialized WER reads it as perfect.
                // Per speaker, A's stream carries four insertions and B's four
                // deletions: eight edits over eight reference words.
                let truth = made([
                    ("A", 0, ["a1", "a2", "a3", "a4"]),
                    ("B", 4, ["b1", "b2", "b3", "b4"]),
                ], seconds: 10)
                let score = BenchScorer.score(
                    truth: truth,
                    utterances: [BenchUtterance(
                        start: 0, end: 8, text: "a1 a2 a3 a4 b1 b2 b3 b4", speakerKey: "c0"
                    )]
                )
                expect.close(score.wer, 0, tolerance: 0.0001, "the serialized stream is exact")
                expect.close(
                    try expect.unwrap(score.cpWer), 1.0, tolerance: 0.0001,
                    "one stream for two speakers pays every misplaced word twice"
                )
            },

            test("a dropped overlap word is a deletion to cpWER and invisible to attribution") {
                expect in
                // The same sixteen-word fixture attribution coverage uses: the
                // last eight words are spoken across each other and the
                // transcript never writes B's overlapped four. Attribution
                // scores the easy half and says so; cpWER charges the four
                // missing words as deletions on B's stream.
                let truth = made([
                    ("A", 0, ["a1", "a2", "a3", "a4"]),
                    ("B", 4, ["b1", "b2", "b3", "b4"]),
                    ("A", 8, ["a5", "a6", "a7", "a8"]),
                    ("B", 8, ["b5", "b6", "b7", "b8"]),
                ], seconds: 12)
                let score = BenchScorer.score(
                    truth: truth,
                    utterances: [
                        BenchUtterance(start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"),
                        BenchUtterance(start: 4, end: 8, text: "b1 b2 b3 b4", speakerKey: "c1"),
                        BenchUtterance(start: 8, end: 12, text: "a5 a6 a7 a8", speakerKey: "c0"),
                    ]
                )
                expect.close(score.attribution, 1.0, tolerance: 0.0001)
                expect.close(
                    try expect.unwrap(score.cpWer), 4.0 / 16.0, tolerance: 0.0001,
                    "the four overlapped words nobody transcribed are deletions"
                )
            },

            test("tcpWER charges words placed far from when they were spoken") { expect in
                // The right words on the right speaker, twenty seconds late.
                // cpWER accepts them; the time-constrained variant refuses the
                // match beyond the five-second collar and pays each word as a
                // deletion where it was said plus an insertion where it landed.
                let truth = made([("A", 0, ["a1", "a2", "a3", "a4"])], seconds: 30)
                let late = BenchScorer.score(
                    truth: truth,
                    utterances: [BenchUtterance(
                        start: 20, end: 24, text: "a1 a2 a3 a4", speakerKey: "c0"
                    )]
                )
                expect.close(try expect.unwrap(late.cpWer), 0, tolerance: 0.0001)
                expect.close(
                    try expect.unwrap(late.tcpWer), 2.0, tolerance: 0.0001,
                    "four deletions and four insertions over four reference words"
                )

                let punctual = BenchScorer.score(
                    truth: truth,
                    utterances: [BenchUtterance(
                        start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"
                    )]
                )
                expect.close(try expect.unwrap(punctual.tcpWer), 0, tolerance: 0.0001)
            },

            test("attribution reports the share of words it asked about") { expect in
                // Sixteen words. The first eight are spoken alone, the last
                // eight across each other, so attribution is asked about half
                // the meeting and says so.
                let truth = made([
                    ("A", 0, ["a1", "a2", "a3", "a4"]),
                    ("B", 4, ["b1", "b2", "b3", "b4"]),
                    ("A", 8, ["a5", "a6", "a7", "a8"]),
                    ("B", 8, ["b5", "b6", "b7", "b8"]),
                ], seconds: 12)
                let score = BenchScorer.score(
                    truth: truth,
                    utterances: [
                        BenchUtterance(start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"),
                        BenchUtterance(start: 4, end: 8, text: "b1 b2 b3 b4", speakerKey: "c1"),
                        BenchUtterance(start: 8, end: 12, text: "a5 a6 a7 a8", speakerKey: "c0"),
                    ]
                )
                expect.equal(score.overlapExcluded, 8, "the overlapping half is not asked")
                expect.equal(score.attributionScored, 8)
                expect.close(
                    score.attributionCoverage, 0.5, tolerance: 0.0001,
                    "half the reference words reached the question"
                )
                expect.close(score.attribution, 1.0, tolerance: 0.0001)
            },

            test("the conversational variant drops backchannels and the plain one does not") {
                expect in
                // "um" is hesitation, "okay" is a backchannel, and an engine
                // that writes neither is charged for one, both or nothing
                // depending on which number is read.
                let truth = made([("A", 0, ["okay", "um", "the", "budget", "is", "fine"])], seconds: 8)
                let score = BenchScorer.score(
                    truth: truth,
                    utterances: [BenchUtterance(
                        start: 0, end: 6, text: "the budget is fine", speakerKey: "c0"
                    )]
                )
                expect.close(score.wer, 2.0 / 6.0, tolerance: 0.0001, "both are missing words")
                expect.close(
                    score.werNoFiller, 1.0 / 5.0, tolerance: 0.0001,
                    "the filler set covers um and leaves okay charged"
                )
                expect.close(
                    score.werConversational, 0, tolerance: 0.0001,
                    "the backchannel set covers okay as well"
                )
            },

            test("DER is reported under both mappings") { expect in
                // Six clusters over four speakers. Merged folds the two extra
                // clusters onto the voices they cover and scores clean; strict
                // leaves them holding their own keys, which is the last 40
                // seconds of A's turn and of B's, 80 of 400 seconds.
                let split = splitCase()
                let score = BenchScorer.score(truth: split.truth, utterances: split.utterances)
                let merged = try expect.unwrap(score.der)
                let strict = try expect.unwrap(score.derStrict)
                expect.close(merged, 0, tolerance: 0.01, "the merged mapping covers every voice")
                expect.close(
                    strict, 0.2, tolerance: 0.01,
                    "the two leftover clusters are 80 of 400 seconds"
                )
            },

            test("a case reports how densely its window is spoken") { expect in
                // Eight seconds of speech in a twenty second window, twelve
                // words in it.
                let truth = made([
                    ("A", 0, ["a1", "a2", "a3", "a4"]),
                    ("B", 6, ["b1", "b2", "b3", "b4"]),
                    ("A", 6, ["a5", "a6", "a7", "a8"]),
                ], seconds: 20)
                let score = BenchScorer.score(
                    truth: truth,
                    utterances: [BenchUtterance(start: 0, end: 4, text: "a1", speakerKey: "c0")]
                )
                expect.close(
                    score.speechCoverage, 0.4, tolerance: 0.0001,
                    "two speakers over the same four seconds are four seconds of speech"
                )
                expect.close(score.wordsPerMinute, 36, tolerance: 0.01)
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

            test("a case with no baseline entry fails when entries are required") { expect in
                let baselines = BenchBaselines(entries: [:])
                let clean = try score(werNoFiller: 0.20, attribution: 0.95, repeats: 0)
                expect.isTrue(
                    baselines.regressions(key: "parakeet/local/Bmr019", score: clean).isEmpty,
                    "an exploratory run without an entry still passes"
                )
                let required = baselines.regressions(
                    key: "parakeet/local/Bmr019", score: clean, requireEntry: true
                )
                expect.equal(
                    required, ["no baseline entry for parakeet/local/Bmr019"],
                    "a gate with a hole in it is not a gate"
                )
            },

            test("tcpWER drift past its tolerance is a regression") { expect in
                let baselines = BenchBaselines(entries: [
                    "parakeet/local/EN2002d": BenchBaselines.Entry(
                        wer: 0.40, werNoFiller: 0.38, attribution: 0.85, der: 0.30,
                        repeatedNgrams: 0, tcpWer: 0.45
                    )
                ])
                let drifted = try score(
                    werNoFiller: 0.38, attribution: 0.85, repeats: 0, tcpWer: 0.50
                )
                expect.equal(
                    baselines.regressions(key: "parakeet/local/EN2002d", score: drifted),
                    ["tcpWER 50.0% against 45.0%"],
                    "five points of per-speaker drift is past the tolerance"
                )
                let steady = try score(
                    werNoFiller: 0.38, attribution: 0.85, repeats: 0, tcpWer: 0.46
                )
                expect.isTrue(
                    baselines.regressions(key: "parakeet/local/EN2002d", score: steady).isEmpty,
                    "one point sits inside the tolerance"
                )
                // An entry recorded before the metric existed compares nothing.
                let legacy = BenchBaselines(entries: [
                    "parakeet/local/EN2002d": BenchBaselines.Entry(
                        wer: 0.40, werNoFiller: 0.38, attribution: 0.85, der: 0.30
                    )
                ])
                expect.isTrue(
                    legacy.regressions(key: "parakeet/local/EN2002d", score: drifted).isEmpty,
                    "no recorded tcpWER means nothing to drift from"
                )
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

            test("every suite in the committed manifest names data that is there") { expect in
                let repository = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let benchmarks = repository.appendingPathComponent("Benchmarks")
                let layout = BenchLayout(root: benchmarks)
                // The harness reads this file with `try?` and carries on
                // without checksums when it fails to decode, so a manifest
                // that stopped decoding would cost verification silently.
                let manifest = try BenchManifest.read(from: layout.manifest)
                expect.equal(manifest.annotations["ami"]?.sha256.count, 64)
                expect.equal(manifest.annotations["icsi"]?.sha256.count, 64)
                for (suite, roster) in manifest.suites {
                    expect.isTrue(!roster.isEmpty, "\(suite) is empty")
                    for meeting in roster {
                        let truth = try BenchTruth.read(from: layout.truth(meeting: meeting))
                        expect.equal(truth.meeting, meeting, "\(suite): truth names \(truth.meeting)")
                        expect.equal(
                            manifest.audio[meeting]?.count, 64,
                            "\(suite): no checksum for \(meeting)"
                        )
                        // The fetch script names the downloaded file after the
                        // last path component of its URL, and the truth's
                        // `source` is what the harness then looks for.
                        let url = manifest.audioURL?[meeting]
                            ?? manifest.mirror.replacingOccurrences(of: "{meeting}", with: meeting)
                        let saved = manifest.audioFilename?[meeting]
                            ?? URL(string: url)?.lastPathComponent
                        expect.equal(
                            saved, truth.source,
                            "\(suite): \(meeting) downloads under another name"
                        )
                    }
                }
            },

            test("the deciding suite holds no meeting an engine may have trained on") { expect in
                // Parakeet's model card lists AMI in its training data, and
                // nine of the fourteen core cases sit in AMI's training
                // partition. A suite that ranks engines must not read them.
                let repository = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let layout = BenchLayout(root: repository.appendingPathComponent("Benchmarks"))
                let manifest = try BenchManifest.read(from: layout.manifest)
                let partition = try expect.unwrap(manifest.partition)
                for meeting in manifest.audio.keys {
                    expect.isTrue(
                        partition[meeting] != nil,
                        "\(meeting) carries no partition, so nobody can tell what it may decide"
                    )
                }
                // Spot checks against the published full-corpus-ASR split.
                expect.equal(partition["ES2002a"], "ami-train")
                expect.equal(partition["IS1008a"], "ami-dev")
                expect.equal(partition["EN2002a"], "ami-eval")
                expect.equal(partition["IB4005"], "excluded")
                expect.equal(partition["Bmr019"], "clean")

                let deciding = try expect.unwrap(manifest.suites["deciding"])
                for meeting in deciding {
                    let held = partition[meeting] ?? "missing"
                    expect.isTrue(
                        held == "ami-eval" || held == "clean",
                        "\(meeting) is \(held): only held-out or uncontaminated data may rank engines"
                    )
                }
                expect.isTrue(deciding.contains("IS1009c"), "the long held-out case is in")
                expect.isTrue(deciding.contains("Bmr019"), "ICSI is in")
            },

            test("the overlap suites share no meeting with the core suite") { expect in
                let repository = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let layout = BenchLayout(root: repository.appendingPathComponent("Benchmarks"))
                let manifest = try BenchManifest.read(from: layout.manifest)
                // The exclusion is a flag on the generator command
                // (`--exclude-suite ami-core`), so forgetting it puts a meeting
                // the core suite already measures into the overlap roster and
                // the two numbers stop being independent.
                let core = Set(manifest.suites["ami-core"] ?? [])
                expect.isTrue(!core.isEmpty, "ami-core is empty")
                for suite in ["ami-overlap", "icsi"] {
                    let roster = Set(manifest.suites[suite] ?? [])
                    expect.isTrue(!roster.isEmpty, "\(suite) is empty")
                    expect.equal(
                        roster.intersection(core).sorted(), [],
                        "\(suite) repeats meetings from ami-core"
                    )
                }
            },

            test("the overlap suites are harder than the core suite") { expect in
                let repository = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let layout = BenchLayout(root: repository.appendingPathComponent("Benchmarks"))
                let manifest = try BenchManifest.read(from: layout.manifest)
                // What the two new suites exist for. A regenerated truth that
                // lost the overlap ranking would still score, and score easy.
                for suite in ["ami-overlap", "icsi"] {
                    for meeting in manifest.suites[suite] ?? [] {
                        let truth = try BenchTruth.read(from: layout.truth(meeting: meeting))
                        let ratio = truth.overlapRatio ?? 0
                        expect.isTrue(
                            ratio >= 0.25, "\(suite)/\(meeting) overlaps \(ratio), under 0.25"
                        )
                    }
                }
            },

            test("repeated runs decide on the mean, and on the worst repeats") { expect in
                let runs = [
                    try run(wer: 0.20, attribution: 0.80, der: 0.30, repeats: 0, deletions: 11),
                    try run(wer: 0.30, attribution: 0.90, der: 0.50, repeats: 7, deletions: 22),
                    try run(wer: 0.40, attribution: 0.70, der: 0.40, repeats: 2, deletions: 33),
                ]
                let deciding = try expect.unwrap(BenchAggregate.deciding(over: runs))
                expect.close(deciding.wer, 0.30, tolerance: 0.0001)
                expect.close(deciding.werNoFiller, 0.15, tolerance: 0.0001)
                expect.close(deciding.werConversational, 0.075, tolerance: 0.0001)
                expect.close(deciding.attribution, 0.80, tolerance: 0.0001)
                expect.close(deciding.attributionMerged, 0.85, tolerance: 0.0001)
                expect.close(deciding.attributionOfLabelled, 0.82, tolerance: 0.0001)
                expect.close(try expect.unwrap(deciding.der), 0.40, tolerance: 0.0001)
                expect.close(try expect.unwrap(deciding.derStrict), 0.50, tolerance: 0.0001)
                expect.equal(
                    deciding.repeatedNgrams, 7,
                    "the repeat budget is worst of the runs, because a defect seen once is one"
                )
                expect.equal(
                    deciding.deletions, 11,
                    "a count describes one transcript and keeps the first run's value"
                )
                expect.equal(deciding.clusterMapping, ["c11": "A"])
                expect.close(deciding.orderingFloorWer, 0.1, tolerance: 0.0001)

                let alone = try expect.unwrap(BenchAggregate.deciding(over: [runs[1]]))
                expect.equal(alone, runs[1], "one run decides as itself")
                expect.isTrue(
                    BenchAggregate.deciding(over: []) == nil, "no runs decide nothing"
                )
            },

            test("repeated runs decide per-speaker error on the mean") { expect in
                let first = try score(werNoFiller: 0.20, attribution: 0.95, repeats: 0, tcpWer: 0.40)
                let second = try score(werNoFiller: 0.20, attribution: 0.95, repeats: 0, tcpWer: 0.50)
                let deciding = try expect.unwrap(BenchAggregate.deciding(over: [first, second]))
                expect.close(
                    try expect.unwrap(deciding.tcpWer), 0.45, tolerance: 0.0001,
                    "the gate reads the mean of the runs"
                )
                let legacy = try score(werNoFiller: 0.20, attribution: 0.95, repeats: 0)
                let mixed = try expect.unwrap(BenchAggregate.deciding(over: [legacy, first]))
                expect.close(
                    try expect.unwrap(mixed.tcpWer), 0.40, tolerance: 0.0001,
                    "a run recorded before the metric existed does not drag the mean"
                )
            },

            test("a resumed run skips what the out file already holds") { expect in
                func row(_ meeting: String, engine: String, diarizer: String, run: Int) throws -> BenchRow {
                    var recorded = try self.score(werNoFiller: 0.2, attribution: 0.9, repeats: 0)
                    recorded.meeting = meeting
                    return BenchRow(
                        engine: engine, diarizer: diarizer, score: recorded,
                        processingSeconds: 60, audioSeconds: 360, state: "complete",
                        transcriptionModels: [], diarizationBackends: [],
                        overlapRatio: nil, run: run, scratch: nil
                    )
                }
                let existing = [
                    try row("ES2002b", engine: "parakeet", diarizer: "local", run: 1),
                    try row("ES2002b", engine: "parakeet", diarizer: "local", run: 3),
                    try row("ES2002b", engine: "cohere", diarizer: "local", run: 1),
                ]
                let plan = BenchResume.pending(
                    existing: existing, meeting: "ES2002b",
                    engine: "parakeet", diarizer: "local", repeats: 3
                )
                expect.equal(plan.runs, [2], "runs one and three are already on disk")
                expect.equal(plan.done.count, 2, "the recorded runs still feed the mean")

                let fresh = BenchResume.pending(
                    existing: existing, meeting: "ES2002b",
                    engine: "parakeet", diarizer: "lseend", repeats: 2
                )
                expect.equal(
                    fresh.runs, [1, 2],
                    "a different diarizer shares nothing with the recorded rows"
                )
                expect.equal(fresh.done.count, 0)
            },

            test("a run with no DER leaves the aggregate without one") { expect in
                let runs = [
                    try run(wer: 0.2, attribution: 0.8, der: nil, repeats: 0, deletions: 1),
                    try run(wer: 0.4, attribution: 0.6, der: nil, repeats: 0, deletions: 2),
                ]
                let deciding = try expect.unwrap(BenchAggregate.deciding(over: runs))
                expect.isTrue(deciding.der == nil, "no run measured DER")
                expect.close(deciding.wer, 0.30, tolerance: 0.0001)
            },
        ])
    }
}
