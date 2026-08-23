import Foundation

/// What one benchmark case measured.
public struct BenchScore: Codable, Sendable, Equatable {
    public var meeting: String
    /// Word error rate against the turn-ordered reference, 0 to 1.
    public var wer: Double
    /// The same with filler tokens and truncated reference words removed.
    public var werNoFiller: Double
    public var substitutions: Int
    public var insertions: Int
    public var deletions: Int
    public var referenceWords: Int
    public var hypothesisWords: Int
    public var utterances: Int
    /// Share of reference words the transcript put on the right speaker, under
    /// the cluster mapping that explains the most words.
    public var attribution: Double
    /// The same over words that landed on some speaker at all.
    public var attributionOfLabelled: Double
    public var attributionScored: Int
    /// Words spoken across another speaker's turn, which one stream of
    /// utterances cannot be right about and which are therefore not asked.
    public var overlapExcluded: Int
    public var referenceSpeakers: Int
    public var hypothesisSpeakers: Int
    public var speakerKeys: [String]
    public var clusterMapping: [String: String]
    public var repeatedNgrams: Int
    public var repeatedShare: Double
    public var overlappingPairs: Int
    public var worstOverlapSeconds: Double
    public var der: Double?
    public var derMissed: Double?
    public var derFalseAlarm: Double?
    public var derConfusion: Double?
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

    static let filler: Set<String> = [
        "mm", "mm-hmm", "hmm", "uh", "um", "mmm", "hm", "uh-huh", "eh", "ah", "oh",
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

    static func tokens(_ texts: [String], dropFiller: Bool = false) -> [String] {
        var out: [String] = []
        for text in texts {
            for token in normalise(text) where !(dropFiller && filler.contains(token)) {
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
        for key in bySpeaker.keys { bySpeaker[key]?.sort { $0.start < $1.start } }

        var ordered: [BenchTruth.Word] = []
        ordered.reserveCapacity(truth.words.count)
        for turn in truth.turns.sorted(by: { $0.start < $1.start }) {
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

    private static func lowerBound(_ words: [BenchTruth.Word], start: Double) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start < start { low = middle + 1 } else { high = middle }
        }
        return low
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
        let ordered = utterances.sorted { $0.start < $1.start }
        let starts = ordered.map(\.start)
        let byStart = turns.sorted { $0.start < $1.start }
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
            pairs.append((word.speaker, best))
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

    /// Assigns hypothesis keys to reference speakers to maximise correct words.
    ///
    /// Exhaustive while the permutations stay cheap, greedy once a diarizer has
    /// over-split badly, which is exactly when the mapping matters most.
    /// Falling through to no mapping at all scored a ten-cluster run as worse
    /// than silence.
    static func bestMapping(
        pairs: [(reference: String, hypothesis: String?)],
        referenceSpeakers: [String],
        hypothesisKeys: [String]
    ) -> (mapping: [String: String], correct: Int) {
        var counts: [String: [String: Int]] = [:]
        for pair in pairs {
            guard let hypothesis = pair.hypothesis else { continue }
            counts[hypothesis, default: [:]][pair.reference, default: 0] += 1
        }
        guard !hypothesisKeys.isEmpty else { return ([:], 0) }

        var mapping: [String: String] = [:]
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
                    mapping = candidate
                }
            }
        } else {
            var flattened: [(hypothesis: String, reference: String, count: Int)] = []
            for (hypothesis, byReference) in counts {
                for (reference, count) in byReference {
                    flattened.append((hypothesis, reference, count))
                }
            }
            flattened.sort { $0.count > $1.count }
            var usedKeys: Set<String> = []
            var usedRefs: Set<String> = []
            for entry in flattened {
                guard !usedKeys.contains(entry.hypothesis), !usedRefs.contains(entry.reference) else {
                    continue
                }
                mapping[entry.hypothesis] = entry.reference
                usedKeys.insert(entry.hypothesis)
                usedRefs.insert(entry.reference)
            }
        }
        // A key left unmapped takes its own most common reference speaker,
        // which is what a user merging clusters would do: a diarizer that split
        // one person into six still has those six pointing at the person they
        // mostly are.
        for key in hypothesisKeys where mapping[key] == nil {
            if let winner = counts[key]?.max(by: { left, right in
                left.value == right.value ? left.key < right.key : left.value < right.value
            }) {
                mapping[key] = winner.key
            }
        }
        return (mapping, scoreMapping(mapping, counts: counts))
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
        for utterance in utterances.sorted(by: { $0.start < $1.start }) {
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
        let ordered = utterances.sorted { $0.start < $1.start }
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
        let utterances = rawUtterances.sorted { $0.start < $1.start }

        let ordered = referenceStream(truth)
        let referenceTokens = tokens(ordered.map(\.text))
        let hypothesisTokens = tokens(utterances.map(\.text))
        let distance = editDistance(reference: referenceTokens, hypothesis: hypothesisTokens)

        let cleanReference = tokens(
            ordered.filter { !$0.truncated }.map(\.text), dropFiller: true
        )
        let cleanHypothesis = tokens(utterances.map(\.text), dropFiller: true)
        let cleanDistance = editDistance(reference: cleanReference, hypothesis: cleanHypothesis)

        let labelled = attribution(words: truth.words, utterances: utterances, turns: truth.turns)
        let keys = Set(utterances.map(\.speakerKey)).filter { !$0.isEmpty }.sorted()
        let mapped = bestMapping(
            pairs: labelled.pairs, referenceSpeakers: truth.speakers, hypothesisKeys: keys
        )
        let labelledCount = labelled.pairs.filter { $0.hypothesis != nil }.count
        let error = diarizationError(
            turns: truth.turns, utterances: utterances,
            mapping: mapped.mapping, duration: truth.windowSeconds
        )
        let repeats = duplication(utterances)
        let overlapping = overlaps(utterances)

        return BenchScore(
            meeting: truth.meeting,
            wer: Double(distance.distance) / Double(max(1, referenceTokens.count)),
            werNoFiller: Double(cleanDistance.distance) / Double(max(1, cleanReference.count)),
            substitutions: distance.substitutions,
            insertions: distance.insertions,
            deletions: distance.deletions,
            referenceWords: referenceTokens.count,
            hypothesisWords: hypothesisTokens.count,
            utterances: utterances.count,
            attribution: Double(mapped.correct) / Double(max(1, labelled.pairs.count)),
            attributionOfLabelled: Double(mapped.correct) / Double(max(1, labelledCount)),
            attributionScored: labelled.pairs.count,
            overlapExcluded: labelled.overlapExcluded,
            referenceSpeakers: truth.speakers.count,
            hypothesisSpeakers: keys.count,
            speakerKeys: keys,
            clusterMapping: mapped.mapping,
            repeatedNgrams: repeats.repeated,
            repeatedShare: repeats.share,
            overlappingPairs: overlapping.pairs,
            worstOverlapSeconds: overlapping.worstSeconds,
            der: error?.der,
            derMissed: error?.missed,
            derFalseAlarm: error?.falseAlarm,
            derConfusion: error?.confusion
        )
    }
}
