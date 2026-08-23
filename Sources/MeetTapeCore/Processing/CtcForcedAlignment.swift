import Foundation

/// Recovers word timings for a transcript whose model returned none, from the
/// frame-by-frame token probabilities of a small CTC model over the same audio.
///
/// This is standard CTC forced alignment: the transcript's tokens, interleaved
/// with blanks, form a state chain, and a Viterbi pass finds the most probable
/// monotonic assignment of frames to states. The math is pure and lives here;
/// producing the log-probabilities from audio is the caller's problem.
public enum CtcForcedAlignment {
    public struct TokenizedWord: Sendable, Equatable {
        public var text: String
        /// Token identifiers in the CTC model's vocabulary. Never empty.
        public var tokens: [Int]

        public init(text: String, tokens: [Int]) {
            self.text = text
            self.tokens = tokens
        }
    }

    public struct AlignedWord: Sendable, Equatable {
        public var text: String
        /// Seconds from the start of the aligned audio.
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Aligns the words against the log-probabilities, or refuses.
    ///
    /// Returns nil when no monotonic path exists (fewer frames than the
    /// transcript needs), when a token is outside the vocabulary, or when the
    /// trellis would exceed `maximumCells`. The caller falls back to
    /// chunk-level timing rather than inventing word times.
    ///
    /// - Parameters:
    ///   - logProbs: One row per frame, one column per vocabulary entry,
    ///     log-softmax values.
    ///   - frameDuration: Seconds each row covers.
    ///   - blankId: The CTC blank's column.
    ///   - words: The transcript, tokenized in the same vocabulary.
    ///   - maximumCells: Backtracking memory cap, one byte per cell. The
    ///     default covers a ten-minute chunk of ordinary speech with room to
    ///     spare and stays far from memory pressure.
    public static func align(
        logProbs: [[Float]],
        frameDuration: Double,
        blankId: Int,
        words: [TokenizedWord],
        maximumCells: Int = 200_000_000
    ) -> [AlignedWord]? {
        guard !words.isEmpty else { return [] }
        let frames = logProbs.count
        guard frames > 0, let vocabularySize = logProbs.first?.count else { return nil }

        // Flatten to one token chain, remembering which word each token spells.
        var tokens: [Int] = []
        var wordOfToken: [Int] = []
        for (index, word) in words.enumerated() {
            guard !word.tokens.isEmpty else { return nil }
            for token in word.tokens {
                guard token >= 0, token < vocabularySize, token != blankId else { return nil }
                tokens.append(token)
                wordOfToken.append(index)
            }
        }

        // States: blank, token 0, blank, token 1, ... blank. Even states are
        // blanks, odd state s is token (s - 1) / 2.
        let stateCount = 2 * tokens.count + 1
        guard frames * stateCount <= maximumCells else { return nil }

        let negativeInfinity = -Float.infinity
        var previous = [Float](repeating: negativeInfinity, count: stateCount)
        var current = previous
        // 0 = stayed, 1 = came from s - 1, 2 = came from s - 2.
        var cameFrom = [UInt8](repeating: 0, count: frames * stateCount)

        previous[0] = logProbs[0][blankId]
        if stateCount > 1 { previous[1] = logProbs[0][tokens[0]] }

        for frame in 1..<frames {
            let row = logProbs[frame]
            let base = frame * stateCount
            for state in 0..<stateCount {
                var best = previous[state]
                var source: UInt8 = 0
                if state >= 1, previous[state - 1] > best {
                    best = previous[state - 1]
                    source = 1
                }
                // A skip reaches a token directly from the previous token,
                // legal only when they differ; equal neighbours need the
                // blank in between, which is what makes CTC decodable.
                if state >= 2, state % 2 == 1 {
                    let token = tokens[(state - 1) / 2]
                    let previousToken = tokens[(state - 3) / 2]
                    if token != previousToken, previous[state - 2] > best {
                        best = previous[state - 2]
                        source = 2
                    }
                }
                if best == negativeInfinity {
                    current[state] = negativeInfinity
                    continue
                }
                let emission = state % 2 == 0 ? row[blankId] : row[tokens[(state - 1) / 2]]
                current[state] = best + emission
                cameFrom[base + state] = source
            }
            swap(&previous, &current)
        }

        // The path must end on the last token or the trailing blank.
        var state: Int
        if stateCount >= 2, previous[stateCount - 2] >= previous[stateCount - 1] {
            state = stateCount - 2
        } else {
            state = stateCount - 1
        }
        guard previous[state] > negativeInfinity else { return nil }

        // Walk back, recording the frames each token owned.
        var firstFrame = [Int](repeating: .max, count: tokens.count)
        var lastFrame = [Int](repeating: .min, count: tokens.count)
        var frame = frames - 1
        while true {
            if state % 2 == 1 {
                let token = (state - 1) / 2
                firstFrame[token] = min(firstFrame[token], frame)
                lastFrame[token] = max(lastFrame[token], frame)
            }
            if frame == 0 { break }
            switch cameFrom[frame * stateCount + state] {
            case 1: state -= 1
            case 2: state -= 2
            default: break
            }
            frame -= 1
        }
        guard firstFrame.allSatisfy({ $0 != .max }) else { return nil }

        var aligned: [AlignedWord] = []
        var tokenIndex = 0
        for (index, word) in words.enumerated() {
            let firstToken = tokenIndex
            let lastToken = tokenIndex + word.tokens.count - 1
            tokenIndex = lastToken + 1
            precondition(wordOfToken[firstToken] == index)
            aligned.append(AlignedWord(
                text: word.text,
                start: Double(firstFrame[firstToken]) * frameDuration,
                end: Double(lastFrame[lastToken] + 1) * frameDuration
            ))
        }
        return aligned
    }

    /// Re-spreads runs of words the Viterbi crammed into single frames.
    ///
    /// Where the acoustic model's posteriors are weak — a distorted voice, a
    /// bad microphone — the best path stacks that stretch's words on whatever
    /// stray peaks match and rides blank over the actual speech. The words
    /// come out one frame long, dozens in a row, at confidently wrong
    /// instants. A run of them is unmistakable, and spreading the run evenly
    /// between its aligned neighbours is honest: roughly where the speech is,
    /// with no false precision. Words the model actually heard keep their
    /// frame-accurate timings.
    public static func spreadCrammedRuns(
        _ words: [AlignedWord], frameDuration: Double, minimumRun: Int = 3
    ) -> [AlignedWord] {
        guard words.count >= minimumRun, frameDuration > 0 else { return words }
        let crammed = words.map { $0.end - $0.start <= frameDuration * 1.5 }

        var spread = words
        var index = 0
        while index < words.count {
            guard crammed[index] else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd + 1 < words.count, crammed[runEnd + 1] { runEnd += 1 }
            defer { index = runEnd + 1 }
            guard runEnd - index + 1 >= minimumRun else { continue }

            // The run belongs somewhere between its aligned neighbours.
            let spanStart = index == 0 ? words[index].start : words[index - 1].end
            let spanEnd = runEnd == words.count - 1 ? words[runEnd].end : words[runEnd + 1].start
            let count = runEnd - index + 1
            guard spanEnd > spanStart else { continue }
            let slice = (spanEnd - spanStart) / Double(count)
            for offset in 0..<count {
                spread[index + offset].start = spanStart + Double(offset) * slice
                spread[index + offset].end = spanStart + Double(offset + 1) * slice
            }
        }
        return spread
    }

    /// Groups aligned words into segments at pauses, capped in length.
    ///
    /// The caps are coarse on purpose: the assembler re-groups into
    /// utterances with its own tuned thresholds, so these segments only need
    /// to be small enough for duplicate detection and honest about pauses.
    public static func segments(
        from words: [AlignedWord], pauseSeconds: Double, maximumSeconds: Double
    ) -> [RawTranscriptSegment] {
        var segments: [RawTranscriptSegment] = []
        var pending: [AlignedWord] = []

        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            segments.append(RawTranscriptSegment(
                start: first.start,
                end: last.end,
                text: pending.map(\.text).joined(separator: " "),
                speaker: nil,
                // Word texts carry a leading space, the Whisper convention the
                // assembler concatenates by.
                words: pending.map {
                    RawTranscriptWord(start: $0.start, end: $0.end, text: " " + $0.text)
                }
            ))
            pending = []
        }

        for word in words {
            if let last = pending.last, let first = pending.first,
                word.start - last.end > pauseSeconds || word.end - first.start > maximumSeconds {
                flush()
            }
            pending.append(word)
        }
        flush()
        return segments
    }
}
