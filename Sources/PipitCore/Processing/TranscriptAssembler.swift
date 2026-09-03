import Foundation

/// Normalised text comparison used to spot the same sentence appearing twice.
public enum TextSimilarity {
    public static func normalise(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Dice coefficient over word bigrams, falling back to word overlap for very
    /// short utterances. 1 means identical, 0 means nothing in common.
    public static func score(_ lhs: String, _ rhs: String) -> Double {
        let left = normalise(lhs)
        let right = normalise(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left.count < 2 || right.count < 2 {
            let shared = Set(left).intersection(right).count
            return Double(2 * shared) / Double(left.count + right.count)
        }
        let leftPairs = bigrams(left)
        let rightPairs = bigrams(right)
        var remaining = rightPairs
        var matches = 0
        for pair in leftPairs {
            if let index = remaining.firstIndex(of: pair) {
                remaining.remove(at: index)
                matches += 1
            }
        }
        return Double(2 * matches) / Double(leftPairs.count + rightPairs.count)
    }

    private static func bigrams(_ words: [String]) -> [String] {
        guard words.count >= 2 else { return words }
        return (0..<(words.count - 1)).map { "\(words[$0]) \(words[$0 + 1])" }
    }
}

/// Turns raw per-chunk API responses into one chronological transcript.
///
/// Three things happen here that the API cannot do for us. Chunk-relative times
/// are moved onto the meeting timeline. Anonymous speaker labels are namespaced
/// per chunk, because "A" in chunk one and "A" in chunk two are not known to be
/// the same person. And the deliberate overlap between chunks is de-duplicated,
/// so a sentence spanning a boundary appears once.
public struct TranscriptAssembler: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Gap between segments of the same speaker that still reads as one turn.
        public var utteranceGapSeconds: Double
        /// Similarity above which two utterances in an overlap are the same text.
        public var duplicateSimilarity: Double
        /// How far either side of an overlapping utterance to look for its twin.
        public var duplicateSearchSeconds: Double
        /// Longest turn one utterance is allowed to span. Without headphones the
        /// microphone hears the remote side too, the audio never goes silent, and
        /// the gap rule alone chained a real recording into one 219-second
        /// utterance that pushed every reply after the whole block.
        public var maxUtteranceSeconds: Double
        /// How far apart two chunks may time the same word and still be talking
        /// about the same moment. Both chunks were aligned against the same
        /// audio, so agreement is usually within tenths of a second; the band is
        /// wider because an aligner that squeezes a phrase onto one timestamp
        /// moves its words by seconds.
        public var overlapMatchSeconds: Double

        public init(
            utteranceGapSeconds: Double = 1.2,
            duplicateSimilarity: Double = 0.62,
            duplicateSearchSeconds: Double = 12,
            maxUtteranceSeconds: Double = 30,
            overlapMatchSeconds: Double = 3
        ) {
            self.utteranceGapSeconds = utteranceGapSeconds
            self.duplicateSimilarity = duplicateSimilarity
            self.duplicateSearchSeconds = duplicateSearchSeconds
            self.maxUtteranceSeconds = maxUtteranceSeconds
            self.overlapMatchSeconds = overlapMatchSeconds
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Builds the canonical transcript.
    ///
    /// - Parameter micTrackIsLocalUser: true for a remote meeting, where the
    ///   microphone is the local user by construction and must never be diarized.
    ///   False for an in-person or imported recording, where the single track
    ///   holds everyone and its raw labels are kept.
    public func assemble(
        raw: RawTranscript,
        micTrackIsLocalUser: Bool,
        generatedAt: Date
    ) -> CanonicalTranscript {
        assemble(
            raw: raw, diarization: RawDiarization(),
            micTrackIsLocalUser: micTrackIsLocalUser, generatedAt: generatedAt
        )
    }

    /// Builds the canonical transcript from words and, where the transcription
    /// backend did not also decide speakers, a separate diarization pass.
    ///
    /// - Parameter diarization: who spoke when. Used only for a track whose
    ///   transcript segments carry no speaker of their own, which is every
    ///   local run and any mixed configuration where words and speakers came
    ///   from different backends.
    /// - Parameter speech: what the recorded audio holds, which decides whether
    ///   the local user said the words written on their track. Nil for a
    ///   meeting processed before the evidence existed, and there every segment
    ///   is kept, which is what those meetings already show.
    /// - Parameter sensors: what the meeting client said about the call. Words
    ///   on the remote track go to the sensor turn covering them first, keyed on
    ///   the platform's participant identifier, because the client observed who
    ///   held the floor rather than inferring it. The diarizer attributes only
    ///   what no turn covers. Nil for every recording made without a readable
    ///   client, which attributes exactly as before.
    public func assemble(
        raw: RawTranscript,
        diarization: RawDiarization,
        speech: SpeechEvidence? = nil,
        sensors: RawSensors? = nil,
        micTrackIsLocalUser: Bool,
        generatedAt: Date
    ) -> CanonicalTranscript {
        // Sensor turns describe the far end alone: the local user's own track
        // never needs them, and an in-person recording never has them.
        let sensorIntervals = sensors.map { SensorAttribution.wordIntervals(sensors: $0) } ?? []
        // The diarized tracks are assembled first so that the local track can be
        // checked against them. A user without headphones plays the remote side
        // through speakers, the microphone records it, and the transcription
        // model writes the remote speakers' words onto the local track. The
        // remote track is authoritative for those words, so a local segment that
        // repeats them nearby in time is echo and is dropped.
        var utterances: [Utterance] = []
        var echoReference: [Utterance] = []
        let orderedTracks = CaptureTrack.allCases.sorted { lhs, _ in
            !(lhs == .mic && micTrackIsLocalUser)
        }
        for track in orderedTracks {
            // Label-only chunks exist when the cloud diarizer ran alongside a
            // local transcription. Their words are a byproduct of asking who
            // spoke; taking them here would render the track twice.
            let chunks = raw.chunks(track: track, purpose: .words)
            guard !chunks.isEmpty else { continue }
            let treatAsLocalUser = track == .mic && micTrackIsLocalUser
            // Sorted so the echo scan can stop at the first utterance past its
            // window instead of walking the whole meeting per segment.
            // A track whose segments already name a speaker keeps them: that
            // is the cloud diarizer's own output and re-deriving it from
            // intervals would change a working result for nothing. A track
            // without them is attributed against the diarization run.
            let carriesSpeakers = chunks.contains { chunk in
                chunk.segments.contains { $0.speaker != nil }
            }
            // A backend that returned its own labels keeps them, unless the user
            // has since re-analysed this track. A re-analysis is the one control
            // that says "cluster this again", and a backend that transcribes and
            // diarizes in one request writes labels into the words themselves,
            // so leaving them in place made Run under Re-analyze speakers write a
            // run nothing read: the panel showed the cloud's original speakers
            // however many times it was pressed.
            let reanalysed = diarization.runs.filter { $0.track == track }.count > 1
            // A run produced by something other than whatever wrote the words
            // is the diarizer the user chose, and it wins from the first pass.
            // Deciding on re-analysis alone meant that transcription in the
            // cloud with diarization set to Local ran the local diarizer, found
            // the right speakers, wrote an active run, and then assembled the
            // transcriber's own chunk-scoped labels anyway: four speakers on
            // disk, ten in the transcript, and Re-analyze speakers as the only
            // way to see the ones that had already been computed. Cloud words
            // with a cloud diarizer still keep their embedded labels, because
            // there the run carries the same producer as the words.
            let activeRun = diarization.activeRun(track: track)
            let separateDiarizer = activeRun.map { run in
                !chunks.contains { $0.model == run.backend }
            } ?? false
            let attributed = (treatAsLocalUser || (carriesSpeakers && !reanalysed && !separateDiarizer))
                ? chunks
                : attribute(
                    chunks, using: activeRun,
                    sensors: track == .remote ? sensorIntervals : []
                )
            let assembled = assembleTrack(
                attributed,
                treatAsLocalUser: treatAsLocalUser,
                echoReference: treatAsLocalUser ? echoReference.sorted { $0.start < $1.start } : [],
                // Only the local user's track. The far end arrives on its own
                // tap, which is silent when nobody is speaking and carries no
                // leakage of anybody else, and the harm this guards against is
                // a sentence the user is shown as having said.
                speech: treatAsLocalUser ? speech : nil
            )
            if !treatAsLocalUser { echoReference.append(contentsOf: assembled) }
            utterances.append(contentsOf: assembled)
        }
        utterances.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.track.rawValue < rhs.track.rawValue : lhs.start < rhs.start
        }
        return CanonicalTranscript(generatedAt: generatedAt, utterances: utterances)
    }

    /// Splits each transcript segment at speaker changes and labels the pieces.
    ///
    /// Every word goes to the diarization interval it overlaps most, then to the
    /// nearest interval within half a second, then nowhere. Measured over a
    /// 15-minute call: 96.3% landed by overlap, 1.2% by the fallback and 2.5%
    /// went unattributed, those last being backchannels spoken over someone
    /// else, which the diarizer drops and the transcriber keeps. An unattributed
    /// run stays with the words around it rather than being invented into a
    /// speaker or dropped.
    private func attribute(
        _ chunks: [RawTranscriptChunk], using run: DiarizationRun?,
        sensors: [DiarizationInterval] = []
    ) -> [RawTranscriptChunk] {
        guard run?.intervals.isEmpty == false || !sensors.isEmpty else { return chunks }
        return chunks.map { chunk in
            var updated = chunk
            updated.segments = chunk.segments.flatMap { segment in
                attribute(
                    segment, chunkOffset: chunk.timelineOffset, run: run, sensors: sensors
                )
            }
            return updated
        }
    }

    /// Assigns each span to the sensor turn covering it, then to a diarization
    /// cluster where no turn does.
    ///
    /// The order is the design. A turn is the meeting client's observation of
    /// who held the floor, so where one covers a word it decides. The diarizer
    /// heard the audio and covers what the client did not see: gaps in the
    /// readings, overlap, and every meeting recorded without a readable client.
    private func assignSpans(
        _ spans: [TimedSpan], sensors: [DiarizationInterval],
        clusters: [DiarizationInterval]
    ) -> [String?] {
        var assigned: [String?]
        if sensors.isEmpty {
            assigned = Array(repeating: nil, count: spans.count)
        } else {
            // No nearest-interval fallback for the sensor tier: a word near a
            // turn but outside it is exactly the release-tail ambiguity the
            // diarizer resolves better, because it hears the voice change.
            (assigned, _) = SpeakerAlignment.assign(
                spans: spans, to: sensors, nearestWithinSeconds: 0
            )
        }
        guard !clusters.isEmpty else { return assigned }
        let leftover = spans.indices.filter { assigned[$0] == nil }
        guard !leftover.isEmpty else { return assigned }
        let (filled, _) = SpeakerAlignment.assign(
            spans: leftover.map { spans[$0] }, to: clusters
        )
        for (position, index) in leftover.enumerated() {
            assigned[index] = filled[position]
        }
        return assigned
    }

    private func attribute(
        _ segment: RawTranscriptSegment, chunkOffset: Double, run: DiarizationRun?,
        sensors: [DiarizationInterval]
    ) -> [RawTranscriptSegment] {
        // Intervals are stored on the meeting timeline; segment times are
        // relative to their chunk, so both are compared in chunk-relative
        // seconds.
        // The run identifier goes into the key, so re-analysing a meeting
        // produces new clusters rather than silently reusing names that
        // belonged to the previous clustering. A sensor key carries no run:
        // it names a person, and a re-analysis does not change who spoke.
        let intervals = (run?.intervals ?? []).map {
            DiarizationInterval(
                start: $0.start - chunkOffset, end: $0.end - chunkOffset,
                clusterID: SpeakerLabel.namespaced(chunkID: run?.id ?? "", rawLabel: $0.clusterID),
                quality: $0.quality
            )
        }
        let sensorIntervals = sensors.map {
            DiarizationInterval(
                start: $0.start - chunkOffset, end: $0.end - chunkOffset,
                clusterID: $0.clusterID, quality: $0.quality
            )
        }

        guard let words = segment.words, !words.isEmpty else {
            // No word timings: the whole segment goes to whichever cluster it
            // overlaps most. Coarser, and the only option a backend that
            // reports segments alone leaves open.
            let clusters = assignSpans(
                [TimedSpan(start: segment.start, end: segment.end)],
                sensors: sensorIntervals, clusters: intervals
            )
            var labelled = segment
            labelled.speaker = clusters.first ?? nil
            return [labelled]
        }

        let spans = words.map { TimedSpan(start: $0.start, end: $0.end) }
        let clusters = assignSpans(spans, sensors: sensorIntervals, clusters: intervals)

        var pieces: [RawTranscriptSegment] = []
        // Seeded with the first speaker named anywhere in this segment, so the
        // words before that point join the turn instead of becoming a line of
        // their own.
        //
        // The diarizer's onset runs late on a turn that opens with a short
        // backchannel. Measured on a Meet recording on 3 September 2026, one
        // turn's words began at 170.56 and its first interval at 174.30, and
        // the inheritance below only ever ran forwards: at the head of a
        // segment there was nothing behind to inherit, so `Okay. Okay,` was cut
        // off the front of its own sentence and rendered speakerless. Nine
        // utterances in that meeting were the same cut.
        //
        // The recogniser's segment is the unit, not the neighbouring turn. One
        // segment is one pass over one stretch of speech, so its own first
        // named speaker is the answer, and a segment naming nobody stays
        // unattributed rather than borrowing from the segment before it.
        var currentSpeaker: String? = clusters.compactMap { $0 }.first
        var currentWords: [RawTranscriptWord] = []

        func flush() {
            guard !currentWords.isEmpty else { return }
            let text = currentWords.map(\.text).joined()
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { currentWords = []; return }
            pieces.append(RawTranscriptSegment(
                start: currentWords[0].start,
                end: currentWords[currentWords.count - 1].end,
                text: text,
                speaker: currentSpeaker,
                words: currentWords
            ))
            currentWords = []
        }

        for (index, word) in words.enumerated() {
            // An unattributed word joins the run it is inside rather than
            // starting one of its own, so a backchannel does not split a turn.
            let speaker = clusters[index] ?? currentSpeaker
            if !currentWords.isEmpty, speaker != currentSpeaker {
                flush()
            }
            currentSpeaker = speaker
            currentWords.append(word)
        }
        flush()
        return pieces.isEmpty ? [segment] : pieces
    }

    /// One word of a chunk on the meeting timeline, and how it compares.
    ///
    /// A chunk whose alignment refused carries one segment holding the whole
    /// chunk's text and no timings at all. Its words are still words, so they
    /// take part here with a nominal position spread across the segment and
    /// `timed` false, which is what keeps a refused chunk from being deleted
    /// wholesale at one seam and duplicated at the other.
    private struct Token {
        var address: TokenAddress
        var start: Double
        var end: Double
        var key: String
        var timed: Bool
    }

    private struct TokenAddress: Hashable {
        var segment: Int
        var index: Int
    }

    /// A token already kept, and the chunk it came from.
    private struct KeptToken {
        var chunk: Int
        var token: Token
    }

    /// Removes, from the seconds two chunks share, the words both of them
    /// transcribed, and only those.
    ///
    /// Adjacent chunks overlap by eight seconds so a sentence on the boundary
    /// lands whole in one of them, and the model transcribes that overlap
    /// twice. Cutting the shared span at its midpoint and handing each half to
    /// one chunk removed the repeats and took real speech with them. Where the
    /// later chunk's transcription or alignment starts past the cut, which the
    /// 35-second Cohere windows do routinely, the earlier chunk's words past
    /// the cut went with nothing to replace them: six minutes of ES2002b gave
    /// 1,041 hypothesis words and 316 deletions before the cut existed and 809
    /// with 470 after it. Worse at a refused alignment, whose one wordless
    /// segment starts at the chunk and so lost the whole chunk whenever it was
    /// the later side of a seam: 2 of 16 chunks refused on one ES2002b run and
    /// 118 transcribed words went with them, which is most of why that engine
    /// swung 6.6 WER points on identical audio.
    ///
    /// So the shared span is settled on content. The two sides' words inside it
    /// are aligned on normalised text, the copy the seam does not need is
    /// dropped, and whatever only one side heard stays. Timings decide the
    /// alignment where both sides have them and where only one does the side
    /// that has them keeps its words, so a refusal costs precision and never
    /// text. Each chunk is compared with every earlier chunk that still reaches
    /// it rather than with its neighbour alone: a chunk whose content runs past
    /// the next boundary overlaps chunk N+2 as well. Matching is confined to
    /// the span the chunks actually share, so two distant chunks that say the
    /// same thing are two chunks that said it, not a seam.
    private func deduplicateOverlaps(_ chunks: [RawTranscriptChunk]) -> [RawTranscriptChunk] {
        let ordered = chunks.sorted { $0.timelineOffset < $1.timelineOffset }
        guard ordered.count > 1 else { return ordered }
        let tolerance = configuration.overlapMatchSeconds
        var dropped: [Int: Set<TokenAddress>] = [:]
        // Every token kept so far, in time order, so the comparison reaches
        // back past the previous chunk.
        var kept: [KeptToken] = []
        var covered = -Double.infinity
        for (index, chunk) in ordered.enumerated() {
            // Nothing that ends before this chunk can start is reachable, and
            // chunks arrive in offset order.
            kept.removeAll { $0.token.end < chunk.timelineOffset - tolerance }
            let tokens = timelineTokens(of: chunk)
            let candidates = tokens.filter { $0.start < covered }
            if let first = candidates.first, let last = candidates.last {
                let window = kept.filter {
                    $0.token.start >= first.start - tolerance
                        && $0.token.start <= last.start + tolerance
                }
                for (earlier, later) in matches(
                    earlier: window.map(\.token), later: candidates, tolerance: tolerance
                ) {
                    let earlierToken = window[earlier]
                    let laterToken = candidates[later]
                    if laterToken.timed, !earlierToken.token.timed {
                        dropped[earlierToken.chunk, default: []].insert(earlierToken.token.address)
                        kept.removeAll {
                            $0.chunk == earlierToken.chunk
                                && $0.token.address == earlierToken.token.address
                        }
                    } else {
                        dropped[index, default: []].insert(laterToken.address)
                    }
                }
            }
            let gone = dropped[index] ?? []
            kept.append(contentsOf: tokens
                .filter { !gone.contains($0.address) }
                .map { KeptToken(chunk: index, token: $0) })
            kept.sort { $0.token.start < $1.token.start }
            // The audio a chunk covers, whether or not its words survived it.
            covered = max(covered, tokens.map(\.end).max() ?? -.infinity)
        }
        return ordered.enumerated().map { index, chunk in
            guard let gone = dropped[index], !gone.isEmpty else { return chunk }
            return removing(gone, from: chunk)
        }
    }

    /// A chunk's words on the meeting timeline, in the order they are spoken.
    ///
    /// Ties are broken by position in the chunk, because an aligner that
    /// squeezes a phrase onto one timestamp would otherwise have its words
    /// reordered by an unstable sort and stop matching the same phrase read
    /// from the chunk beside it.
    private func timelineTokens(of chunk: RawTranscriptChunk) -> [Token] {
        var tokens: [Token] = []
        for (segmentIndex, segment) in chunk.segments.enumerated() {
            if let words = segment.words, !words.isEmpty {
                for (wordIndex, word) in words.enumerated() {
                    tokens.append(Token(
                        address: TokenAddress(segment: segmentIndex, index: wordIndex),
                        start: chunk.timelineOffset + word.start,
                        end: chunk.timelineOffset + word.end,
                        key: normalisedUnit(word.text),
                        timed: true
                    ))
                }
                continue
            }
            // An unaligned segment says what was said and not when. Its words
            // are laid evenly across it so they sort and window with the rest;
            // the spacing is a guess, which is why they never match on time.
            let texts = segment.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            let span = max(segment.end - segment.start, 0)
            let step = span / Double(texts.count)
            for (textIndex, text) in texts.enumerated() {
                let start = chunk.timelineOffset + segment.start + step * Double(textIndex)
                tokens.append(Token(
                    address: TokenAddress(segment: segmentIndex, index: textIndex),
                    start: start, end: start + step,
                    key: normalisedUnit(text),
                    timed: false
                ))
            }
        }
        tokens.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.address.segment != rhs.address.segment {
                return lhs.address.segment < rhs.address.segment
            }
            return lhs.address.index < rhs.address.index
        }
        return tokens
    }

    /// The pairs of positions the two sides agree on: a longest common
    /// subsequence over normalised text where two timed words may only match if
    /// the chunks timed them within `tolerance` of each other. Order is part of
    /// the test, so a filler word cannot pair with a twin several sentences
    /// away.
    private func matches(
        earlier: [Token], later: [Token], tolerance: Double
    ) -> [(Int, Int)] {
        guard !earlier.isEmpty, !later.isEmpty else { return [] }
        let rows = earlier.count
        let columns = later.count
        var table = [Int](repeating: 0, count: (rows + 1) * (columns + 1))
        func index(_ row: Int, _ column: Int) -> Int { row * (columns + 1) + column }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if pairs(earlier[row], later[column], tolerance: tolerance) {
                    table[index(row, column)] = table[index(row + 1, column + 1)] + 1
                } else {
                    table[index(row, column)] = max(
                        table[index(row + 1, column)], table[index(row, column + 1)]
                    )
                }
            }
        }
        var matched: [(Int, Int)] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if pairs(earlier[row], later[column], tolerance: tolerance) {
                matched.append((row, column))
                row += 1
                column += 1
            } else if table[index(row + 1, column)] >= table[index(row, column + 1)] {
                row += 1
            } else {
                column += 1
            }
        }
        return matched
    }

    /// Two renderings of one spoken word: the same text, or one transcription
    /// error apart on a word long enough for that to mean something, at a
    /// moment both chunks agree on. A side with no timings is placed by the
    /// order of what it says, so only the shared span and that order hold it.
    private func pairs(_ lhs: Token, _ rhs: Token, tolerance: Double) -> Bool {
        if lhs.timed, rhs.timed, abs(lhs.start - rhs.start) > tolerance { return false }
        if lhs.key == rhs.key { return true }
        return withinOneEdit(lhs.key, rhs.key)
    }

    private func withinOneEdit(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 5, rhs.count >= 5, abs(lhs.count - rhs.count) <= 1 else { return false }
        let left = Array(lhs)
        let right = Array(rhs)
        var leftIndex = 0
        var rightIndex = 0
        var edits = 0
        while leftIndex < left.count, rightIndex < right.count {
            if left[leftIndex] == right[rightIndex] {
                leftIndex += 1
                rightIndex += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if left.count == right.count {
                leftIndex += 1
                rightIndex += 1
            } else if left.count > right.count {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }
        return edits + (left.count - leftIndex) + (right.count - rightIndex) <= 1
    }

    /// One chunk without the named words, and without a segment they emptied.
    /// An unaligned segment keeps the span it was given, because nothing in it
    /// says where the words that remain begin.
    private func removing(
        _ dropped: Set<TokenAddress>, from chunk: RawTranscriptChunk
    ) -> RawTranscriptChunk {
        var trimmed = chunk
        trimmed.segments = chunk.segments.enumerated().compactMap { index, segment in
            if let words = segment.words, !words.isEmpty {
                let kept = words.enumerated()
                    .filter { !dropped.contains(TokenAddress(segment: index, index: $0.offset)) }
                    .map(\.element)
                if kept.count == words.count { return segment }
                guard let first = kept.first, let last = kept.last else { return nil }
                let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return RawTranscriptSegment(
                    start: first.start, end: last.end, text: text,
                    speaker: segment.speaker, words: kept
                )
            }
            let texts = segment.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            let kept = texts.enumerated()
                .filter { !dropped.contains(TokenAddress(segment: index, index: $0.offset)) }
                .map(\.element)
            if kept.count == texts.count { return segment }
            guard !kept.isEmpty else { return nil }
            return RawTranscriptSegment(
                start: segment.start, end: segment.end,
                text: kept.joined(separator: " "), speaker: segment.speaker, words: nil
            )
        }
        return trimmed
    }

    private func assembleTrack(
        _ chunks: [RawTranscriptChunk], treatAsLocalUser: Bool, echoReference: [Utterance],
        speech: SpeechEvidence?
    ) -> [Utterance] {
        var accepted: [Utterance] = []
        for chunk in deduplicateOverlaps(chunks) {
            let candidates = utterances(
                from: chunk, treatAsLocalUser: treatAsLocalUser, echoReference: echoReference,
                speech: speech
            )
            for candidate in candidates {
                if isDuplicate(candidate, of: accepted) { continue }
                guard let trimmed = trimmingSeamRepeat(candidate, after: accepted.last)
                else { continue }
                accepted.append(trimmed)
            }
        }
        return accepted
    }

    /// Groups consecutive same-speaker segments into readable turns and moves
    /// them onto the meeting timeline.
    private func utterances(
        from chunk: RawTranscriptChunk, treatAsLocalUser: Bool, echoReference: [Utterance],
        speech: SpeechEvidence?
    ) -> [Utterance] {
        var result: [Utterance] = []
        var current: (
            start: Double, end: Double, speaker: String?, text: String,
            words: [RawTranscriptWord], timed: Bool
        )?

        func flush() {
            guard let group = current, !group.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                current = nil
                return
            }
            let rawLabel = group.speaker.map {
                SpeakerLabel.namespaced(chunkID: chunk.id, rawLabel: $0)
            }
            let speakerKey = treatAsLocalUser
                ? SpeakerLabel.localUser
                : (rawLabel ?? SpeakerLabel.unattributed(track: chunk.track))
            // Two turns of one chunk that round to the same millisecond would
            // otherwise share an identifier, and a correction aimed at one would
            // land on the other. Rare enough that the suffix never appears in
            // practice, cheap enough to keep uniqueness a property rather than a
            // hope.
            var identifier = Utterance.identifier(
                chunkID: chunk.id, track: chunk.track,
                start: chunk.timelineOffset + group.start,
                end: chunk.timelineOffset + group.end
            )
            var collisions = 0
            while result.contains(where: { $0.id == identifier }) {
                collisions += 1
                identifier = Utterance.identifier(
                    chunkID: chunk.id, track: chunk.track,
                    start: chunk.timelineOffset + group.start,
                    end: chunk.timelineOffset + group.end
                ) + "-\(collisions)"
            }
            result.append(Utterance(
                id: identifier,
                start: chunk.timelineOffset + group.start,
                end: chunk.timelineOffset + group.end,
                track: chunk.track,
                rawSpeakerLabel: treatAsLocalUser ? nil : rawLabel,
                speakerKey: speakerKey,
                text: group.text.trimmingCharacters(in: .whitespaces),
                chunkID: chunk.id,
                model: chunk.model,
                // On the meeting timeline, like the line's own start and end.
                // A division of this line is compared against corrections and
                // diarization intervals, which are all in those coordinates.
                //
                // Present only when every segment in the turn was timed. A
                // dividing line's text is rebuilt from its words, so a partial
                // list would delete the untimed half of the turn from the
                // panel, the markdown and everything derived from them. A
                // decoder does return a segment with no word alignment, and a
                // text-only backend's chunk has none at all.
                words: group.timed ? group.words.map {
                    RawTranscriptWord(
                        start: chunk.timelineOffset + $0.start,
                        end: chunk.timelineOffset + $0.end,
                        text: $0.text, probability: $0.probability
                    )
                } : nil
            ))
            current = nil
        }

        // Once per chunk rather than once per segment; it is a property of the
        // whole series.
        let farEndUsable = speech?.farEndCarriesSignal ?? false
        for original in chunk.segments.sorted(by: { $0.start < $1.start }) {
            let whole = original.text.trimmingCharacters(in: .whitespaces)
            guard !whole.isEmpty else { continue }
            if isEcho(
                whole,
                start: chunk.timelineOffset + original.start,
                end: chunk.timelineOffset + original.end,
                reference: echoReference
            ) { continue }
            // Whole-segment judgements above, word-level below. A recogniser
            // segment runs to about thirty seconds and routinely holds both the
            // far end leaking through the speakers and the user's own answer to
            // it, so neither keeping nor dropping the whole thing is right.
            // One run at a time, not one stretch at a time. The cut leaves the
            // user's own words in runs with the far end's between them, and a
            // single reading spanning the first run to the last still covers
            // that leakage: on a Slack huddle recorded on 3 September 2026 it
            // read 9.9 dB against a 0.4 dB threshold and deleted all 3957 words
            // the user said, leaving them absent from their own meeting.
            let cut = trimmingEcho(
                original, chunkOffset: chunk.timelineOffset, reference: echoReference
            )
            for segment in cut.runs {
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // Measured over what is left, not over what arrived. A run the cut
                // reduced to the user's own words is judged on those.
                let start = chunk.timelineOffset + segment.start
                let end = chunk.timelineOffset + segment.end
                if var reading = speech?.reading(from: start, to: end, farEndUsable: farEndUsable) {
                    // The cut has already asked, and answered better, the
                    // question the echo clause asks. Leakage is the far end's
                    // words arriving a second time, so a run its own transcript
                    // does not contain is not leakage, whatever is playing
                    // underneath it.
                    //
                    // The clause measures energy, and on speakers the far end
                    // plays under the user continuously, so it reads their own
                    // voice as leakage: on the Slack huddle of 3 September 2026
                    // it deleted 18 words and then 45 more, at 1.47 dB and
                    // 5.08 dB against a 0.4 dB threshold. The user asked a
                    // question, the far end answered it, and only the answer
                    // reached the transcript. Its own documentation gives this
                    // as the cost, a voice needing about 12 dB over the leak.
                    //
                    // Only where the far end's words were actually available to
                    // compare against. The level clauses are untouched either
                    // way, so a run that is loud far end and quiet user still
                    // goes.
                    if cut.comparedWithFarEnd { reading.echoReturnLossDB = nil }
                    if LocalSpeechPolicy.decide(text: text, reading: reading) == .notSpoken {
                        continue
                    }
                }
                if var group = current,
                   group.speaker == segment.speaker,
                   segment.start - group.end <= configuration.utteranceGapSeconds,
                   segment.end - group.start <= configuration.maxUtteranceSeconds {
                    group.end = max(group.end, segment.end)
                    group.text += group.text.isEmpty ? text : " \(text)"
                    group.words += segment.words ?? []
                    group.timed = group.timed && !(segment.words ?? []).isEmpty
                    current = group
                } else {
                    flush()
                    current = (
                        segment.start, segment.end, segment.speaker, text,
                        segment.words ?? [], !(segment.words ?? []).isEmpty
                    )
            }
            }
        }
        flush()
        return result
    }

    /// How many words in a row have to match the far end before the run is its
    /// leakage rather than a coincidence.
    ///
    /// Two is not enough. "you know" and "i think" recur all meeting on both
    /// tracks and matching on them alone cut real speech apart.
    private static let echoRunWords = 3

    /// How close two runs of leakage have to be for what lies between them to be
    /// leakage as well.
    ///
    /// The two tracks are the same sound heard twice, so the recogniser
    /// disagrees with itself across them: on the 3 September recording the far
    /// end reads "from scratcher" where the microphone reads "from scratch
    /// here". Matching on words alone leaves those disagreements standing in
    /// the middle of a stretch that is otherwise all far end, and enough of
    /// them in a row survive the length rule below.
    ///
    /// Leakage is continuous in time. A hole inside it is the recogniser
    /// disagreeing, not the user speaking, and two seconds is longer than any
    /// of those holes and shorter than the pause before a real answer. Over the
    /// whole archive it changes one other meeting by ten words.
    private static let echoBridgeSeconds = 2.0

    /// How much has to survive between two runs of leakage to be worth keeping.
    ///
    /// A handful of words stranded inside a stretch of the far end is the
    /// recogniser's noise on leaked audio, not a turn. Either length settles it,
    /// because a slow speaker says few words in a long time.
    private static let keptRunWords = 5
    private static let keptRunSeconds = 2.0

    /// Cuts the far end's own words out of a local-track segment, and returns
    /// nil when nothing the user said is left.
    ///
    /// The far end's track is the reference: the same sentence is in both,
    /// because the microphone heard it come out of the speakers. Text, not
    /// audio, so it needs no delay measurement, no level comparison and no
    /// aligned tracks, and it repairs a meeting already on disk by reassembling
    /// what the recogniser wrote rather than transcribing it again.
    ///
    /// A segment with no word timings cannot be cut and keeps whatever the
    /// whole-segment rules above decided.
    private func trimmingEcho(
        _ segment: RawTranscriptSegment, chunkOffset: Double, reference: [Utterance]
    ) -> (runs: [RawTranscriptSegment], comparedWithFarEnd: Bool) {
        guard !reference.isEmpty, let words = segment.words, !words.isEmpty else {
            return ([segment], false)
        }
        let window = configuration.duplicateSearchSeconds
        let start = chunkOffset + segment.start
        let end = chunkOffset + segment.end
        // Every far-end word said near enough in time to be this segment's
        // source, as one token run per utterance.
        var references: [[String]] = []
        for utterance in reference {
            if utterance.start > end + window { break }
            guard utterance.end > start - window else { continue }
            let tokens = TextSimilarity.normalise(utterance.text)
            if !tokens.isEmpty { references.append(tokens) }
        }
        guard !references.isEmpty else { return ([segment], false) }

        let tokens = words.map { TextSimilarity.normalise($0.text).joined() }
        var echoed = [Bool](repeating: false, count: words.count)
        for index in tokens.indices where !tokens[index].isEmpty {
            var longest = 0
            for candidate in references {
                for origin in candidate.indices {
                    var length = 0
                    while index + length < tokens.count,
                          origin + length < candidate.count,
                          !tokens[index + length].isEmpty,
                          tokens[index + length] == candidate[origin + length] {
                        length += 1
                    }
                    longest = max(longest, length)
                }
            }
            if longest >= TranscriptAssembler.echoRunWords {
                for offset in 0..<longest { echoed[index + offset] = true }
            }
        }

        // Close the recogniser's disagreements before measuring what survives.
        let marked = echoed.indices.filter { echoed[$0] }
        for (left, right) in zip(marked, marked.dropFirst())
        where words[right].start - words[left].end < TranscriptAssembler.echoBridgeSeconds {
            for between in left..<right { echoed[between] = true }
        }

        var runs: [RawTranscriptSegment] = []
        var index = 0
        var cutAnything = false
        while index < words.count {
            guard !echoed[index] else { index += 1; cutAnything = true; continue }
            var run = index
            while run < words.count, !echoed[run] { run += 1 }
            let slice = Array(words[index..<run])
            let seconds = (slice.last?.end ?? 0) - (slice.first?.start ?? 0)
            defer { index = run }
            guard slice.count >= TranscriptAssembler.keptRunWords
                || seconds >= TranscriptAssembler.keptRunSeconds
            else { cutAnything = true; continue }
            let text = slice.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let first = slice.first, let last = slice.last else {
                cutAnything = true
                continue
            }
            runs.append(RawTranscriptSegment(
                start: first.start, end: last.end, text: text,
                speaker: segment.speaker, words: slice
            ))
        }
        return (cutAnything ? runs : [segment], true)
    }

    /// A local-track segment that repeats what a diarized track already says
    /// nearby in time. The window is generous because a transcription model's
    /// timestamps drift by whole sentences on audio that carries speaker bleed.
    private func isEcho(
        _ text: String, start: Double, end: Double, reference: [Utterance]
    ) -> Bool {
        guard !reference.isEmpty else { return false }
        let window = configuration.duplicateSearchSeconds
        for utterance in reference {
            if utterance.start > end + window { break }
            guard utterance.end > start - window else { continue }
            if TextSimilarity.score(utterance.text, text) >= configuration.duplicateSimilarity {
                return true
            }
            if text.count >= 12, utterance.text.lowercased().contains(text.lowercased()) {
                return true
            }
        }
        return false
    }

    /// Drops the opening words of a line that repeat the closing words of the
    /// line before it, and returns nil when nothing is left.
    ///
    /// Adjacent chunks overlap by eight seconds so a sentence on the boundary
    /// lands whole in one of them, and the model transcribes that overlap
    /// twice. `isDuplicate` removes a line that is wholly a repeat; a line that
    /// begins with one and then carries on is the common case and used to be
    /// kept intact. Measured on a 25-minute meeting: 21 of 148 consecutive
    /// pairs repeated between 3 and 17 words, every one of them across a chunk
    /// boundary and 20 of them over shared time. Separate timecodes rendered
    /// that as a stutter. One paragraph per speaker renders it as nonsense.
    ///
    /// Three words minimum, and only where the two lines really share time. The
    /// overlap tail is audio the earlier chunk already covered, so a genuine
    /// seam repeat is always spoken at a moment the previous line still holds.
    /// Two lines that follow one another in time are two different pieces of
    /// audio, and a speaker who ends on "that makes sense to me" and opens the
    /// next turn the same way keeps both.
    private func trimmingSeamRepeat(_ candidate: Utterance, after previous: Utterance?) -> Utterance? {
        guard let previous, previous.chunkID != candidate.chunkID else { return candidate }
        guard rangesOverlap(previous, candidate) else { return candidate }
        let before = units(of: previous)
        let after = units(of: candidate)
        var repeated = 0
        for count in stride(from: min(before.count, after.count), through: minimumSeamWords, by: -1)
        where Array(before.suffix(count)) == Array(after.prefix(count)) {
            repeated = count
            break
        }
        guard repeated > 0 else { return candidate }
        return dropping(repeated, from: candidate)
    }

    /// Words already repeated once are speech, not overlap, below this.
    private var minimumSeamWords: Int { 3 }

    /// Shortest line the whole-turn duplicate check will delete.
    private var minimumDuplicateWords: Int { 4 }

    /// One line's words as they compare: the timed words where the backend
    /// reported them, and whitespace-separated text where it did not. Both
    /// sides normalise the same way, so a line with timings compares against
    /// one without.
    private func units(of utterance: Utterance) -> [String] {
        if let words = utterance.words, !words.isEmpty {
            return words.map(normalisedUnit)
        }
        return utterance.text
            .components(separatedBy: .whitespacesAndNewlines)
            .map(normalisedUnit)
            .filter { !$0.isEmpty }
    }

    private func normalisedUnit(_ word: RawTranscriptWord) -> String {
        normalisedUnit(word.text)
    }

    private func normalisedUnit(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Removes the first `count` words from a line, moving its start to where
    /// the words that remain begin. A line whose words were not timed keeps its
    /// start, because nothing on it says where the repeat ended.
    private func dropping(_ count: Int, from utterance: Utterance) -> Utterance? {
        var trimmed = utterance
        if let words = utterance.words, !words.isEmpty {
            let remaining = Array(words.dropFirst(count))
            guard let first = remaining.first else { return nil }
            let text = remaining.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            trimmed.words = remaining
            trimmed.text = text
            trimmed.start = first.start
        } else {
            let remaining = utterance.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .dropFirst(count)
            let text = remaining.joined(separator: " ")
            guard !text.isEmpty else { return nil }
            trimmed.text = text
        }
        trimmed.id = Utterance.identifier(
            chunkID: trimmed.chunkID, track: trimmed.track,
            start: trimmed.start, end: trimmed.end
        )
        return trimmed
    }

    /// An utterance in the overlap region that repeats something already accepted.
    private func isDuplicate(_ candidate: Utterance, of accepted: [Utterance]) -> Bool {
        // A backchannel is not a duplicate of the next backchannel. "Yeah"
        // scores 1.0 against any other "Yeah" inside the search window, and the
        // seconds two chunks share are now settled word by word before this
        // runs, so a short line that survived that is a line somebody said.
        guard TextSimilarity.normalise(candidate.text).count >= minimumDuplicateWords else {
            return false
        }
        for existing in accepted.reversed() {
            if candidate.start - existing.end > configuration.duplicateSearchSeconds { break }
            // Repeats inside one chunk are speech, not overlap. A speaker who says
            // "yes, exactly" twice in a minute keeps both.
            guard existing.chunkID != candidate.chunkID else { continue }
            guard abs(existing.start - candidate.start) <= configuration.duplicateSearchSeconds
                || rangesOverlap(existing, candidate)
            else { continue }
            if TextSimilarity.score(existing.text, candidate.text) >= configuration.duplicateSimilarity {
                return true
            }
            // A chunk boundary can split one turn so that the later chunk repeats
            // only the tail of it.
            if existing.text.count > candidate.text.count,
               candidate.text.count >= 12,
               existing.text.lowercased().contains(candidate.text.lowercased()) {
                return true
            }
        }
        return false
    }

    private func rangesOverlap(_ lhs: Utterance, _ rhs: Utterance) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }
}

/// Renders the canonical transcript for reading.
///
/// Rendering resolves speaker names at display time, so changing a name never
/// touches the transcript or the raw diarization behind it.
/// One person in the participant block, as the transcript introduces them.
///
/// What a reader downstream needs before the first line of dialogue: who was
/// talking, where they work, and whatever the user wrote about them.
public struct TranscriptParticipant: Sendable, Equatable {
    public var name: String
    public var organization: String?
    public var notes: String?

    public init(name: String, organization: String? = nil, notes: String? = nil) {
        self.name = name
        self.organization = organization
        self.notes = notes
    }

    /// A participant with nothing but a name adds nothing the dialogue does not
    /// already say, so the block is built from the ones that do.
    public var isInformative: Bool {
        let organization = self.organization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = self.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !organization.isEmpty || !notes.isEmpty
    }
}

public struct TranscriptRenderer: Sendable {
    public init() {}

    public func markdown(
        transcript: CanonicalTranscript,
        speakers: SpeakerMap,
        title: String,
        startedAt: Date,
        durationSeconds: Double,
        participants: [TranscriptParticipant]
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("\(startedAt.formatted(date: .long, time: .shortened)) · \(formatDuration(durationSeconds))")
        lines.append("")
        lines.append(contentsOf: participantBlock(participants))

        var lastSpeaker: String?
        for utterance in transcript.utterances {
            // Resolved from the utterance, not from its cluster key, so a
            // single corrected line renders as corrected here too.
            let name = speakers.resolvedName(for: utterance)
            if name != lastSpeaker {
                lines.append("")
                lines.append("**\(name)** · \(timecode(utterance.start))")
                lastSpeaker = name
            }
            lines.append(utterance.text)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Written above the dialogue, because a reader who meets the notes after
    /// the conversation has already decided who everybody is.
    private func participantBlock(_ participants: [TranscriptParticipant]) -> [String] {
        let informative = participants.filter(\.isInformative)
        guard !informative.isEmpty else { return [] }
        var lines = ["## Participants", ""]
        for participant in informative {
            var line = "- **\(participant.name)**"
            if let organization = participant.organization?
                .trimmingCharacters(in: .whitespacesAndNewlines), !organization.isEmpty {
                line += " · \(organization)"
            }
            lines.append(line)
            if let notes = participant.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                // Indented under the name so a multi-line note stays inside the
                // list item instead of ending it.
                for note in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(note)")
                }
            }
        }
        lines.append("")
        return lines
    }

    public func plainText(transcript: CanonicalTranscript, speakers: SpeakerMap) -> String {
        transcript.utterances.map { utterance in
            "[\(timecode(utterance.start))] \(speakers.resolvedName(for: utterance)): \(utterance.text)"
        }.joined(separator: "\n")
    }

    public func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
