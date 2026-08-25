import Foundation

/// What one benchmark case measured.
public struct BenchScore: Codable, Sendable, Equatable {
    public var meeting: String
    /// Word error rate against the turn-ordered reference, 0 to 1.
    public var wer: Double
    /// The same with filler tokens and truncated reference words removed.
    public var werNoFiller: Double
    /// The same again with backchannels removed from both sides.
    ///
    /// A clean-style engine writes none of "yeah", "okay", "right", "yep", and
    /// the AMI annotators wrote all of them: 3.6% of reference tokens over the
    /// suite, charged as deletions against an engine whose only fault is house
    /// style. Reported beside `werNoFiller`, never in place of it, because the
    /// baselines read `werNoFiller` and a backchannel a system does write is
    /// still a word it got right.
    public var werConversational: Double
    /// Word error rate of an oracle transcript holding every reference word in
    /// chronological order.
    ///
    /// This is one particular ordering, not a bound: edit distance is a metric
    /// over the turn-grouped reference, and a hypothesis that groups a passage
    /// by utterance can score below the chronological oracle. `netOfFloorWer`
    /// clamps at zero for that reason.
    ///
    /// The reference stream is grouped by turn and a transcript is a stream of
    /// utterances, so overlapping speech interleaves in one and not the other.
    /// Over the suite this floor runs 6.2% to 33.1% per case, and on the
    /// overlap-heavy files it is most of the gap between two engines. Read
    /// `wer` against it, not on its own.
    public var orderingFloorWer: Double
    public var substitutions: Int
    public var insertions: Int
    public var deletions: Int
    public var referenceWords: Int
    public var hypothesisWords: Int
    public var utterances: Int
    /// Share of reference words the transcript put on the right speaker, under
    /// the best injective cluster mapping: each reference speaker is claimed by
    /// at most one cluster, and a cluster left over contributes nothing.
    ///
    /// This is the number the baselines and the regression rule read. A
    /// diarizer that splits one voice into six is wrong about five of them,
    /// and the deciding run must not pay it for the split.
    public var attribution: Double
    /// The same after every leftover cluster is folded onto the reference
    /// speaker it mostly covers, which is what a user merging clusters by hand
    /// would recover. Reported, never decided on.
    public var attributionMerged: Double
    /// The strict share over words that landed on some speaker at all.
    public var attributionOfLabelled: Double
    public var attributionScored: Int
    /// Words spoken across another speaker's turn, which one stream of
    /// utterances cannot be right about and which are therefore not asked.
    public var overlapExcluded: Int
    /// Share of the reference words that attribution asked about at all, so
    /// the excluded overlap is on the page next to the number it shaped.
    ///
    /// 22.7% of the suite's words are excluded, and 50.1% of EN2002a's. An
    /// attribution figure with no coverage beside it reads as a score over the
    /// meeting when it is a score over the easy half of one.
    public var attributionCoverage: Double
    public var referenceSpeakers: Int
    public var hypothesisSpeakers: Int
    public var speakerKeys: [String]
    public var clusterMapping: [String: String]
    public var repeatedNgrams: Int
    public var repeatedShare: Double
    public var overlappingPairs: Int
    public var worstOverlapSeconds: Double
    /// Diarization error rate under the merged cluster mapping, which is the
    /// basis the baselines read.
    ///
    /// Merged is the right basis here and strict is the right basis for
    /// attribution: attribution already charges an over-splitting diarizer for
    /// every cluster beyond the first, so scoring DER strictly would charge it
    /// a second time for the same fault, in a second headline number. Both are
    /// reported so nobody has to reconstruct which mapping produced which
    /// figure.
    ///
    /// A DER above 100% is arithmetic, not a defect: the denominator is
    /// reference speech time and false alarm counts hypothesis speech outside
    /// it, which is unbounded above. This is the standard NIST definition.
    public var der: Double?
    /// The same under the injective mapping, where a leftover cluster keeps its
    /// own key and every frame it covers is confusion. Reported, never decided
    /// on.
    ///
    /// An unmapped key is compared against reference speaker names directly, so
    /// a cluster keyed with a reference speaker's own name would score as
    /// correct on those frames. Generated keys are `c0`, `speaker_1` and the
    /// like, so it does not arise today.
    public var derStrict: Double?
    public var derMissed: Double?
    public var derFalseAlarm: Double?
    public var derConfusion: Double?
    /// Share of the scored window that holds reference speech, and reference
    /// words per minute of window.
    ///
    /// Cases differ by a factor of three on both: ES2003a is 31.3% covered at
    /// 64 words per minute, and every case but ES2002a (59.5%, 103) runs 78%
    /// to 99% and 146 to 217. A sparse case decides its WER on a third as many
    /// words as its neighbours, so one error moves it three times as far.
    /// Derived from the truth's own turns and words rather than stored, so a
    /// truth file regenerated by hand carries them too.
    public var speechCoverage: Double
    public var wordsPerMinute: Double
    /// Concatenated minimum-permutation word error rate: each speaker's words
    /// concatenated on both sides, hypothesis keys paired one-to-one with
    /// reference speakers by whichever pairing costs the fewest edits, total
    /// edits over total reference words.
    ///
    /// This is the number that scores overlapped speech at all. The serialized
    /// `wer` interleaves simultaneous speakers into one stream and pays an
    /// ordering floor for it, and `attribution` declines to ask about words
    /// spoken across another turn. Per speaker there is no interleaving and no
    /// exclusion: a talked-over word nobody transcribed is a deletion, a word
    /// on the wrong voice is charged on both streams. Optional because scores
    /// recorded before the metric existed decode without it.
    public var cpWer: Double?
    /// `cpWer` with a time constraint: a word only matches inside
    /// `BenchScorer.tcpCollar` seconds of when it was said, so the right words
    /// pasted at the wrong time are charged. The CHiME convention, which makes
    /// the figure comparable with published meeting-transcription systems.
    public var tcpWer: Double?

    /// `wer` with the ordering floor taken off, clamped at zero.
    ///
    /// A directional lower bound on the share of `wer` that is not ordering,
    /// never a split of one into the other. The two overlap: an edit an engine
    /// pays for a missing word is often an edit the oracle pays for reading
    /// turns in one stream, and ES2002b scores 18.5% against an 18.1% floor
    /// while holding at least 10.1 points of deletions of its own.
    ///
    /// The clamp exists because the floor is one particular oracle ordering
    /// and a hypothesis can order a passage more cheaply than it does; below
    /// zero the subtraction has nothing left to say.
    public var netOfFloorWer: Double { max(0, wer - orderingFloorWer) }
}

/// The meter. Pure arithmetic over a reference and a transcript, ported metric
/// for metric from the Python scorer the model-path probe validated, so a
/// number from the harness is comparable with the numbers measured by hand.
public enum BenchScorer {
    /// Frame width for DER, in seconds.
    public static let frame = 0.01
    /// Frames this close to a reference turn boundary are not scored, which is
    /// the standard forgiveness for annotation edges.
    public static let collar = 0.25

    /// Hesitation noise. 6.7% of the reference tokens over the suite.
    ///
    /// `normalise` splits on hyphens, so "mm-hmm" and "uh-huh" arrive as two
    /// tokens and both halves have to be listed for the pair to disappear.
    static let filler: Set<String> = [
        "mm", "mm-hmm", "hmm", "uh", "um", "mmm", "hm", "uh-huh", "eh", "ah", "oh",
    ]

    /// Backchannels: words a listener says to show they are listening. Another
    /// 3.6% of the reference tokens, "yeah" 558 times and "okay" 282.
    ///
    /// Held apart from `filler` and dropped only in `werConversational`,
    /// because these are ordinary English words in every other position:
    /// "right" is a direction and an agreement, and charging a system for
    /// writing one is as wrong as charging it for omitting the other. The
    /// variant answers one question only, how much of an engine's WER is house
    /// style rather than error.
    static let backchannel: Set<String> = [
        "yeah", "yep", "yup", "yah", "okay", "ok", "right",
    ]

    // MARK: - text

    /// Lowercased, punctuation dropped, hyphens split. Apostrophes survive
    /// because "don't" and "dont" are not the same word to a reader.
    public static func normalise(_ text: String) -> [String] {
        var scalars = String.UnicodeScalarView()
        for character in text.lowercased().unicodeScalars {
            let scalar = character == "\u{2019}" ? Unicode.Scalar("'") : character
            switch scalar {
            case "a"..."z", "0"..."9", "'":
                scalars.append(scalar)
            case "-":
                scalars.append(" ")
            default:
                scalars.append(" ")
            }
        }
        return String(scalars).split(separator: " ").map(String.init)
    }

    static func tokens(
        _ texts: [String], dropFiller: Bool = false, dropBackchannel: Bool = false
    ) -> [String] {
        var out: [String] = []
        for text in texts {
            for token in normalise(text) {
                if dropFiller && filler.contains(token) { continue }
                if dropBackchannel && backchannel.contains(token) { continue }
                out.append(token)
            }
        }
        return out
    }

    /// Levenshtein distance with the substitution, insertion and deletion split.
    static func editDistance(
        reference: [String], hypothesis: [String]
    ) -> (distance: Int, substitutions: Int, insertions: Int, deletions: Int) {
        var previous = Array(0...hypothesis.count)
        // (substitutions, insertions, deletions) behind each cell.
        var opsPrevious = (0...hypothesis.count).map { (0, $0, 0) }
        for (row, referenceToken) in reference.enumerated() {
            var current = [row + 1]
            var opsCurrent = [(0, 0, row + 1)]
            current.reserveCapacity(hypothesis.count + 1)
            opsCurrent.reserveCapacity(hypothesis.count + 1)
            for (column, hypothesisToken) in hypothesis.enumerated() {
                let cost: Int
                let ops: (Int, Int, Int)
                if referenceToken == hypothesisToken {
                    cost = previous[column]
                    ops = opsPrevious[column]
                } else {
                    let substitute = previous[column] + 1
                    let insert = current[column] + 1
                    let delete = previous[column + 1] + 1
                    if substitute <= insert && substitute <= delete {
                        cost = substitute
                        let base = opsPrevious[column]
                        ops = (base.0 + 1, base.1, base.2)
                    } else if insert <= delete {
                        cost = insert
                        let base = opsCurrent[column]
                        ops = (base.0, base.1 + 1, base.2)
                    } else {
                        cost = delete
                        let base = opsPrevious[column + 1]
                        ops = (base.0, base.1, base.2 + 1)
                    }
                }
                current.append(cost)
                opsCurrent.append(ops)
            }
            previous = current
            opsPrevious = opsCurrent
        }
        let final = opsPrevious[hypothesis.count]
        return (previous[hypothesis.count], final.0, final.1, final.2)
    }

    // MARK: - reference ordering

    /// The reference words in the order a turn-grouped transcript reads them.
    ///
    /// Ordering by word start time alone punishes every system for overlapping
    /// speech: a transcript groups a speaker's turn together, so two people
    /// talking at once interleave in one stream and not the other. Grouping the
    /// reference by turn compares like with like, and an oracle transcript then
    /// scores zero.
    public static func referenceStream(_ truth: BenchTruth) -> [BenchTruth.Word] {
        var bySpeaker: [String: [BenchTruth.Word]] = [:]
        for word in truth.words { bySpeaker[word.speaker, default: []].append(word) }
        for key in bySpeaker.keys { bySpeaker[key]?.sort(by: wordOrder) }

        var ordered: [BenchTruth.Word] = []
        ordered.reserveCapacity(truth.words.count)
        for turn in truth.turns.sorted(by: turnOrder) {
            guard let candidates = bySpeaker[turn.speaker] else { continue }
            // The words are sorted, so the turn's slice is a contiguous range.
            var index = lowerBound(candidates, start: turn.start - 0.001)
            while index < candidates.count, candidates[index].start <= turn.end + 0.001 {
                let word = candidates[index]
                if word.end <= turn.end + 0.001 { ordered.append(word) }
                index += 1
            }
        }
        return ordered
    }

    /// What an oracle transcript costs for word order alone.
    ///
    /// The hypothesis is the reference's own words, every one of them, in
    /// chronological order: nothing is missing, nothing is invented, nothing is
    /// misspelled. What is left is the distance between one stream of
    /// utterances and a turn-grouped reference, which is what every real
    /// transcript pays before it makes a single transcription error. Subtract
    /// it from `wer` to compare two engines on an overlap-heavy case.
    public static func orderingFloor(_ truth: BenchTruth) -> Double {
        let ordered = referenceStream(truth)
        let reference = tokens(ordered.map(\.text))
        guard !reference.isEmpty else { return 0 }
        // The same words, so only their order differs from the reference.
        let chronological = tokens(ordered.sorted(by: wordOrder).map(\.text))
        let distance = editDistance(reference: reference, hypothesis: chronological).distance
        return Double(distance) / Double(reference.count)
    }

    /// Reference speech as a share of the scored window, and reference words
    /// per minute of it. Overlapping turns count once.
    static func density(_ truth: BenchTruth) -> (coverage: Double, wordsPerMinute: Double) {
        guard truth.windowSeconds > 0 else { return (0, 0) }
        var spoken = 0.0
        var reach = -Double.infinity
        for turn in truth.turns.sorted(by: turnOrder) {
            let start = max(turn.start, reach)
            if turn.end > start { spoken += turn.end - start }
            reach = max(reach, turn.end)
        }
        return (
            spoken / truth.windowSeconds,
            Double(truth.words.count) / (truth.windowSeconds / 60)
        )
    }

    /// Equal starts are ordered by end and then by text, so two words at the
    /// same moment cannot swap between runs.
    static func wordOrder(_ left: BenchTruth.Word, _ right: BenchTruth.Word) -> Bool {
        if left.start != right.start { return left.start < right.start }
        if left.end != right.end { return left.end < right.end }
        return left.text < right.text
    }

    static func turnOrder(_ left: BenchTruth.Turn, _ right: BenchTruth.Turn) -> Bool {
        if left.start != right.start { return left.start < right.start }
        if left.end != right.end { return left.end < right.end }
        return left.speaker < right.speaker
    }

    static func utteranceOrder(_ left: BenchUtterance, _ right: BenchUtterance) -> Bool {
        if left.start != right.start { return left.start < right.start }
        if left.end != right.end { return left.end < right.end }
        if left.speakerKey != right.speakerKey { return left.speakerKey < right.speakerKey }
        return left.text < right.text
    }

    private static func lowerBound(_ words: [BenchTruth.Word], start: Double) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start < start { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: - per-speaker word error

    /// Words this far from when they were said do not match under `tcpWer`.
    /// Five seconds is the collar the CHiME challenges score with, and it is
    /// wide enough that spreading an utterance's words evenly across its span
    /// stands in for exact word timings, which is how MeetEval's own validation
    /// runs when a system reports segment times only.
    public static let tcpCollar = 5.0

    /// A normalised token with the span it was spoken over.
    struct TimedToken {
        var text: String
        var start: Double
        var end: Double
    }

    /// Each reference speaker's words as timed tokens, in the order that
    /// speaker said them. The word set is `referenceStream`'s, so `cpWer` and
    /// `wer` score the same words.
    static func referenceSpeakerStreams(_ truth: BenchTruth) -> [String: [TimedToken]] {
        var streams: [String: [TimedToken]] = [:]
        for word in referenceStream(truth) {
            for part in normalise(word.text) {
                streams[word.speaker, default: []].append(
                    TimedToken(text: part, start: word.start, end: word.end))
            }
        }
        return streams
    }

    /// Each hypothesis key's words as timed tokens, each utterance's tokens
    /// spread evenly across its span. An utterance with no key still holds
    /// words somebody said, so it forms a stream of its own rather than
    /// vanishing.
    static func hypothesisSpeakerStreams(_ utterances: [BenchUtterance]) -> [String: [TimedToken]] {
        var streams: [String: [TimedToken]] = [:]
        for utterance in utterances.sorted(by: utteranceOrder) {
            let parts = normalise(utterance.text)
            guard !parts.isEmpty else { continue }
            let width = max(0, utterance.end - utterance.start) / Double(parts.count)
            for (index, part) in parts.enumerated() {
                let start = utterance.start + Double(index) * width
                streams[utterance.speakerKey, default: []].append(
                    TimedToken(text: part, start: start, end: start + width))
            }
        }
        return streams
    }

    /// Levenshtein distance where, under a collar, two words may only match or
    /// substitute while their spans lie within it; a distant pair can only be
    /// paid as a deletion plus an insertion.
    static func timedEditDistance(
        reference: [TimedToken], hypothesis: [TimedToken], collar: Double?
    ) -> Int {
        var previous = Array(0...hypothesis.count)
        for (row, referenceToken) in reference.enumerated() {
            var current = [row + 1]
            current.reserveCapacity(hypothesis.count + 1)
            for (column, hypothesisToken) in hypothesis.enumerated() {
                var best = min(current[column] + 1, previous[column + 1] + 1)
                let plausible = collar.map {
                    hypothesisToken.start <= referenceToken.end + $0
                        && referenceToken.start <= hypothesisToken.end + $0
                } ?? true
                if plausible {
                    let diagonal = previous[column]
                        + (referenceToken.text == hypothesisToken.text ? 0 : 1)
                    best = min(best, diagonal)
                }
                current.append(best)
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    /// The cheapest one-to-one pairing of reference streams with hypothesis
    /// streams, in total edits. The shorter side is padded with empty streams,
    /// so an unmatched reference speaker costs their words as deletions and an
    /// unmatched key costs its words as insertions.
    static func streamAssignmentCost(
        reference: [[TimedToken]], hypothesis: [[TimedToken]], collar: Double?
    ) -> Int {
        let n = max(reference.count, hypothesis.count)
        guard n > 0 else { return 0 }
        var cost = [[Int]](repeating: [Int](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                let ref = i < reference.count ? reference[i] : []
                let hyp = j < hypothesis.count ? hypothesis[j] : []
                if ref.isEmpty {
                    cost[i][j] = hyp.count
                } else if hyp.isEmpty {
                    cost[i][j] = ref.count
                } else {
                    cost[i][j] = timedEditDistance(reference: ref, hypothesis: hyp, collar: collar)
                }
            }
        }
        if n <= 18 {
            // Exact assignment over column subsets: table[mask] is the best
            // cost of pairing the first popcount(mask) rows with the columns
            // in mask.
            var table = [Int](repeating: .max, count: 1 << n)
            table[0] = 0
            for mask in 0..<(1 << n) where table[mask] != .max {
                let row = mask.nonzeroBitCount
                guard row < n else { continue }
                for column in 0..<n where mask & (1 << column) == 0 {
                    let candidate = table[mask] + cost[row][column]
                    let next = mask | (1 << column)
                    if candidate < table[next] { table[next] = candidate }
                }
            }
            return table[(1 << n) - 1]
        }
        // Past eighteen streams the mask no longer fits; a diarizer that
        // over-split that badly is being measured, not ranked, so a greedy
        // pairing with deterministic ties is enough.
        var pairs: [(row: Int, column: Int)] = []
        for i in 0..<n {
            for j in 0..<n { pairs.append((i, j)) }
        }
        pairs.sort { left, right in
            if cost[left.row][left.column] != cost[right.row][right.column] {
                return cost[left.row][left.column] < cost[right.row][right.column]
            }
            if left.row != right.row { return left.row < right.row }
            return left.column < right.column
        }
        var usedRows: Set<Int> = []
        var usedColumns: Set<Int> = []
        var total = 0
        for pair in pairs where !usedRows.contains(pair.row) && !usedColumns.contains(pair.column) {
            usedRows.insert(pair.row)
            usedColumns.insert(pair.column)
            total += cost[pair.row][pair.column]
        }
        return total
    }

    /// `cpWer` and `tcpWer` for one case.
    static func perSpeakerWordError(
        truth: BenchTruth, utterances: [BenchUtterance]
    ) -> (cp: Double, tcp: Double) {
        let referenceStreams = referenceSpeakerStreams(truth)
        let hypothesisStreams = hypothesisSpeakerStreams(utterances)
        let reference = referenceStreams.keys.sorted().compactMap { referenceStreams[$0] }
        let hypothesis = hypothesisStreams.keys.sorted().compactMap { hypothesisStreams[$0] }
        let words = max(1, reference.reduce(0) { $0 + $1.count })
        let cp = streamAssignmentCost(reference: reference, hypothesis: hypothesis, collar: nil)
        let tcp = streamAssignmentCost(
            reference: reference, hypothesis: hypothesis, collar: tcpCollar)
        return (Double(cp) / Double(words), Double(tcp) / Double(words))
    }

    // MARK: - attribution

    /// Reference words labelled by the hypothesis utterance covering them.
    ///
    /// Words spoken across another speaker's turn are excluded: one stream of
    /// utterances cannot be right about both, and a diarizer is not asked to
    /// be. The covering utterance is the one sharing the most time with the
    /// word, so two utterances that touch do not decide it by document order.
    static func attribution(
        words: [BenchTruth.Word], utterances: [BenchUtterance], turns: [BenchTruth.Turn]
    ) -> (pairs: [(reference: String, hypothesis: String?)], overlapExcluded: Int) {
        let ordered = utterances.sorted(by: utteranceOrder)
        let starts = ordered.map(\.start)
        let byStart = turns.sorted(by: turnOrder)
        let turnStarts = byStart.map(\.start)
        let longestTurn = byStart.map { $0.end - $0.start }.max() ?? 0
        let longestUtterance = ordered.map { $0.end - $0.start }.max() ?? 0

        var pairs: [(reference: String, hypothesis: String?)] = []
        pairs.reserveCapacity(words.count)
        var excluded = 0
        for word in words {
            if overlapped(word: word, turns: byStart, starts: turnStarts, longest: longestTurn) {
                excluded += 1
                continue
            }
            var best: String?
            var bestShare = 0.0
            var index = max(0, indexBefore(starts, word.start - longestUtterance))
            while index < ordered.count, ordered[index].start < word.end {
                let utterance = ordered[index]
                let share = min(utterance.end, word.end) - max(utterance.start, word.start)
                if share > bestShare {
                    best = utterance.speakerKey
                    bestShare = share
                }
                index += 1
            }
            if bestShare <= 0 {
                let middle = (word.start + word.end) / 2
                for utterance in ordered where utterance.start <= middle && middle <= utterance.end {
                    best = utterance.speakerKey
                    break
                }
            }
            // An utterance with no speaker key is unlabelled, not labelled with
            // the empty string: the key list drops it, so a pair holding it
            // would count against a mapping that cannot contain it.
            pairs.append((word.speaker, (best?.isEmpty ?? true) ? nil : best))
        }
        return (pairs, excluded)
    }

    private static func indexBefore(_ starts: [Double], _ value: Double) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Whether another speaker is talking across this word.
    private static func overlapped(
        word: BenchTruth.Word, turns: [BenchTruth.Turn], starts: [Double], longest: Double
    ) -> Bool {
        var index = indexBefore(starts, word.start - longest)
        while index < turns.count, turns[index].start < word.end {
            let turn = turns[index]
            if turn.speaker != word.speaker, turn.end > word.start { return true }
            index += 1
        }
        return false
    }

    /// One cluster-to-speaker solution, scored both ways.
    public struct Mapping: Sendable, Equatable {
        /// Each reference speaker claimed by at most one cluster.
        public var injective: [String: String]
        /// The same with every leftover cluster folded onto its majority
        /// speaker.
        public var merged: [String: String]
        public var strictCorrect: Int
        public var mergedCorrect: Int
    }

    /// Assigns hypothesis keys to reference speakers to maximise correct words.
    ///
    /// Exhaustive while the permutations stay cheap, greedy once a diarizer has
    /// over-split badly, which is exactly when the mapping matters most.
    /// Falling through to no mapping at all scored a ten-cluster run as worse
    /// than silence.
    ///
    /// Both branches produce the same two numbers: the injective mapping is
    /// scored on its own, and the fill of leftover clusters is scored
    /// separately. Scoring only after the fill rewards over-splitting, because
    /// every extra cluster lands on the speaker it mostly covers and counts as
    /// correct.
    public static func bestMapping(
        pairs: [(reference: String, hypothesis: String?)],
        referenceSpeakers: [String],
        hypothesisKeys: [String]
    ) -> Mapping {
        var counts: [String: [String: Int]] = [:]
        for pair in pairs {
            guard let hypothesis = pair.hypothesis else { continue }
            counts[hypothesis, default: [:]][pair.reference, default: 0] += 1
        }
        guard !hypothesisKeys.isEmpty else {
            return Mapping(injective: [:], merged: [:], strictCorrect: 0, mergedCorrect: 0)
        }

        var injective: [String: String] = [:]
        if hypothesisKeys.count <= 7 && referenceSpeakers.count <= 7 {
            var bestScore = -1
            let keys = hypothesisKeys
            let refs = referenceSpeakers
            let keysAreLonger = keys.count >= refs.count
            let longer = keysAreLonger ? keys : refs
            let shorter = keysAreLonger ? refs : keys
            permutations(of: longer, taking: shorter.count) { arrangement in
                var candidate: [String: String] = [:]
                for (offset, element) in arrangement.enumerated() {
                    // The arrangement runs over whichever list is longer, and
                    // the mapping always reads hypothesis key to reference.
                    if keysAreLonger {
                        candidate[element] = shorter[offset]
                    } else {
                        candidate[shorter[offset]] = element
                    }
                }
                let score = scoreMapping(candidate, counts: counts)
                if score > bestScore {
                    bestScore = score
                    injective = candidate
                }
            }
        } else {
            var flattened: [(hypothesis: String, reference: String, count: Int)] = []
            for (hypothesis, byReference) in counts {
                for (reference, count) in byReference {
                    flattened.append((hypothesis, reference, count))
                }
            }
            // A Swift dictionary iterates in a per-process random order and
            // count ties are common, so the comparator decides every tie
            // itself: without the names in it the same input scores two
            // different mappings on two runs.
            flattened.sort { left, right in
                if left.count != right.count { return left.count > right.count }
                if left.reference != right.reference { return left.reference < right.reference }
                return left.hypothesis < right.hypothesis
            }
            var usedKeys: Set<String> = []
            var usedRefs: Set<String> = []
            for entry in flattened {
                guard !usedKeys.contains(entry.hypothesis), !usedRefs.contains(entry.reference) else {
                    continue
                }
                injective[entry.hypothesis] = entry.reference
                usedKeys.insert(entry.hypothesis)
                usedRefs.insert(entry.reference)
            }
        }
        // A key left unmapped takes its own most common reference speaker,
        // which is what a user merging clusters would do: a diarizer that split
        // one person into six still has those six pointing at the person they
        // mostly are.
        var merged = injective
        for key in hypothesisKeys where merged[key] == nil {
            if let winner = counts[key]?.max(by: { left, right in
                left.value == right.value ? left.key < right.key : left.value < right.value
            }) {
                merged[key] = winner.key
            }
        }
        return Mapping(
            injective: injective,
            merged: merged,
            strictCorrect: scoreMapping(injective, counts: counts),
            mergedCorrect: scoreMapping(merged, counts: counts)
        )
    }

    private static func scoreMapping(
        _ mapping: [String: String], counts: [String: [String: Int]]
    ) -> Int {
        var total = 0
        for (hypothesis, byReference) in counts {
            guard let reference = mapping[hypothesis] else { continue }
            total += byReference[reference] ?? 0
        }
        return total
    }

    private static func permutations(
        of elements: [String], taking count: Int, _ body: ([String]) -> Void
    ) {
        var chosen: [String] = []
        var used = [Bool](repeating: false, count: elements.count)
        func step() {
            if chosen.count == count {
                body(chosen)
                return
            }
            for index in elements.indices where !used[index] {
                used[index] = true
                chosen.append(elements[index])
                step()
                chosen.removeLast()
                used[index] = false
            }
        }
        step()
    }

    // MARK: - diarization

    struct DiarizationError {
        var der: Double
        var missed: Double
        var falseAlarm: Double
        var confusion: Double
    }

    /// Frame-based DER with a collar, overlap counted against the system once.
    static func diarizationError(
        turns: [BenchTruth.Turn], utterances: [BenchUtterance],
        mapping: [String: String], duration: Double
    ) -> DiarizationError? {
        let frameCount = Int(duration / frame)
        guard frameCount > 0 else { return nil }
        var reference = [Set<String>](repeating: [], count: frameCount)
        for turn in turns {
            let lower = max(0, Int(turn.start / frame))
            let upper = min(frameCount, Int(turn.end / frame))
            guard lower < upper else { continue }
            for index in lower..<upper { reference[index].insert(turn.speaker) }
        }
        var hypothesis = [Set<String>](repeating: [], count: frameCount)
        for utterance in utterances {
            let speaker = mapping[utterance.speakerKey] ?? utterance.speakerKey
            let lower = max(0, Int(utterance.start / frame))
            let upper = min(frameCount, Int(utterance.end / frame))
            guard lower < upper else { continue }
            for index in lower..<upper { hypothesis[index].insert(speaker) }
        }
        var scored = [Bool](repeating: true, count: frameCount)
        for turn in turns {
            for edge in [turn.start, turn.end] {
                let lower = max(0, Int((edge - collar) / frame))
                let upper = min(frameCount, Int((edge + collar) / frame))
                guard lower < upper else { continue }
                for index in lower..<upper { scored[index] = false }
            }
        }

        var total = 0.0
        var missed = 0.0
        var falseAlarm = 0.0
        var confusion = 0.0
        for index in 0..<frameCount where scored[index] {
            let referenceFrame = reference[index]
            let hypothesisFrame = hypothesis[index]
            total += Double(referenceFrame.count)
            if referenceFrame.isEmpty {
                falseAlarm += Double(hypothesisFrame.count)
                continue
            }
            if hypothesisFrame.isEmpty {
                missed += Double(referenceFrame.count)
                continue
            }
            let correct = referenceFrame.intersection(hypothesisFrame).count
            let shortfall = max(0, referenceFrame.count - max(correct, hypothesisFrame.count))
            missed += Double(shortfall)
            falseAlarm += Double(max(0, hypothesisFrame.count - referenceFrame.count))
            confusion += Double(referenceFrame.count - correct - shortfall)
        }
        guard total > 0 else { return nil }
        return DiarizationError(
            der: (missed + falseAlarm + confusion) / total,
            missed: missed / total,
            falseAlarm: falseAlarm / total,
            confusion: confusion / total
        )
    }

    // MARK: - transcript shape

    /// Repeated word n-grams, which is what a missed overlap de-duplication
    /// looks like: a chunked backend transcribes the overlapping audio twice
    /// and the same sentence appears at two timestamps, sometimes on two
    /// speakers. Counted as a share of the stream so it compares across
    /// transcripts of different lengths.
    static func duplication(
        _ utterances: [BenchUtterance], width: Int = 8
    ) -> (repeated: Int, share: Double) {
        var words: [String] = []
        for utterance in utterances.sorted(by: utteranceOrder) {
            words.append(contentsOf: normalise(utterance.text))
        }
        guard words.count > width else { return (0, 0) }
        var seen: Set<String> = []
        var repeats = 0
        for index in 0...(words.count - width) {
            let gram = words[index..<(index + width)].joined(separator: " ")
            if seen.contains(gram) { repeats += 1 } else { seen.insert(gram) }
        }
        return (repeats, Double(repeats) / Double(words.count - width + 1))
    }

    /// Pairs of utterances whose spans overlap, and the worst overlap seen.
    static func overlaps(_ utterances: [BenchUtterance]) -> (pairs: Int, worstSeconds: Double) {
        let ordered = utterances.sorted(by: utteranceOrder)
        var pairs = 0
        var worst = 0.0
        for (index, first) in ordered.enumerated() {
            for second in ordered[(index + 1)...] {
                if second.start >= first.end { break }
                let share = min(first.end, second.end) - second.start
                if share > 0 {
                    pairs += 1
                    worst = max(worst, share)
                }
            }
        }
        return (pairs, worst)
    }

    // MARK: - the whole report

    public static func score(truth: BenchTruth, utterances rawUtterances: [BenchUtterance]) -> BenchScore {
        let utterances = rawUtterances.sorted(by: utteranceOrder)

        let ordered = referenceStream(truth)
        let referenceTokens = tokens(ordered.map(\.text))
        let hypothesisTokens = tokens(utterances.map(\.text))
        let distance = editDistance(reference: referenceTokens, hypothesis: hypothesisTokens)

        let cleanReference = tokens(
            ordered.filter { !$0.truncated }.map(\.text), dropFiller: true
        )
        let cleanHypothesis = tokens(utterances.map(\.text), dropFiller: true)
        let cleanDistance = editDistance(reference: cleanReference, hypothesis: cleanHypothesis)

        let conversationalReference = tokens(
            ordered.filter { !$0.truncated }.map(\.text),
            dropFiller: true, dropBackchannel: true
        )
        let conversationalHypothesis = tokens(
            utterances.map(\.text), dropFiller: true, dropBackchannel: true
        )
        let conversationalDistance = editDistance(
            reference: conversationalReference, hypothesis: conversationalHypothesis
        )

        let labelled = attribution(words: truth.words, utterances: utterances, turns: truth.turns)
        let keys = Set(utterances.map(\.speakerKey)).filter { !$0.isEmpty }.sorted()
        let mapped = bestMapping(
            pairs: labelled.pairs, referenceSpeakers: truth.speakers, hypothesisKeys: keys
        )
        let labelledCount = labelled.pairs.filter { $0.hypothesis != nil }.count
        let error = diarizationError(
            turns: truth.turns, utterances: utterances,
            mapping: mapped.merged, duration: truth.windowSeconds
        )
        let strictError = diarizationError(
            turns: truth.turns, utterances: utterances,
            mapping: mapped.injective, duration: truth.windowSeconds
        )
        let repeats = duplication(utterances)
        let overlapping = overlaps(utterances)
        let shape = density(truth)
        let asked = labelled.pairs.count + labelled.overlapExcluded
        let perSpeaker = perSpeakerWordError(truth: truth, utterances: utterances)

        return BenchScore(
            meeting: truth.meeting,
            wer: Double(distance.distance) / Double(max(1, referenceTokens.count)),
            werNoFiller: Double(cleanDistance.distance) / Double(max(1, cleanReference.count)),
            werConversational: Double(conversationalDistance.distance)
                / Double(max(1, conversationalReference.count)),
            orderingFloorWer: orderingFloor(truth),
            substitutions: distance.substitutions,
            insertions: distance.insertions,
            deletions: distance.deletions,
            referenceWords: referenceTokens.count,
            hypothesisWords: hypothesisTokens.count,
            utterances: utterances.count,
            attribution: Double(mapped.strictCorrect) / Double(max(1, labelled.pairs.count)),
            attributionMerged: Double(mapped.mergedCorrect) / Double(max(1, labelled.pairs.count)),
            attributionOfLabelled: Double(mapped.strictCorrect) / Double(max(1, labelledCount)),
            attributionScored: labelled.pairs.count,
            overlapExcluded: labelled.overlapExcluded,
            attributionCoverage: Double(labelled.pairs.count) / Double(max(1, asked)),
            referenceSpeakers: truth.speakers.count,
            hypothesisSpeakers: keys.count,
            speakerKeys: keys,
            clusterMapping: mapped.merged,
            repeatedNgrams: repeats.repeated,
            repeatedShare: (repeats.share * 10000).rounded() / 10000,
            overlappingPairs: overlapping.pairs,
            worstOverlapSeconds: (overlapping.worstSeconds * 100).rounded() / 100,
            der: error?.der,
            derStrict: strictError?.der,
            derMissed: error?.missed,
            derFalseAlarm: error?.falseAlarm,
            derConfusion: error?.confusion,
            speechCoverage: (shape.coverage * 10000).rounded() / 10000,
            wordsPerMinute: (shape.wordsPerMinute * 100).rounded() / 100,
            cpWer: perSpeaker.cp,
            tcpWer: perSpeaker.tcp
        )
    }
}
