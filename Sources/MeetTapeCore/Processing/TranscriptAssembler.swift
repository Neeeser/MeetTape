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

        public init(
            utteranceGapSeconds: Double = 1.2,
            duplicateSimilarity: Double = 0.62,
            duplicateSearchSeconds: Double = 12,
            maxUtteranceSeconds: Double = 30
        ) {
            self.utteranceGapSeconds = utteranceGapSeconds
            self.duplicateSimilarity = duplicateSimilarity
            self.duplicateSearchSeconds = duplicateSearchSeconds
            self.maxUtteranceSeconds = maxUtteranceSeconds
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
    public func assemble(
        raw: RawTranscript,
        diarization: RawDiarization,
        micTrackIsLocalUser: Bool,
        generatedAt: Date
    ) -> CanonicalTranscript {
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
            let attributed = (treatAsLocalUser || (carriesSpeakers && !reanalysed))
                ? chunks
                : attribute(chunks, using: diarization.activeRun(track: track))
            let assembled = assembleTrack(
                attributed,
                treatAsLocalUser: treatAsLocalUser,
                echoReference: treatAsLocalUser ? echoReference.sorted { $0.start < $1.start } : []
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
        _ chunks: [RawTranscriptChunk], using run: DiarizationRun?
    ) -> [RawTranscriptChunk] {
        guard let run, !run.intervals.isEmpty else { return chunks }
        return chunks.map { chunk in
            var updated = chunk
            updated.segments = chunk.segments.flatMap { segment in
                attribute(segment, chunkOffset: chunk.timelineOffset, run: run)
            }
            return updated
        }
    }

    private func attribute(
        _ segment: RawTranscriptSegment, chunkOffset: Double, run: DiarizationRun
    ) -> [RawTranscriptSegment] {
        // Intervals are stored on the meeting timeline; segment times are
        // relative to their chunk, so both are compared in chunk-relative
        // seconds.
        // The run identifier goes into the key, so re-analysing a meeting
        // produces new clusters rather than silently reusing names that
        // belonged to the previous clustering.
        let intervals = run.intervals.map {
            DiarizationInterval(
                start: $0.start - chunkOffset, end: $0.end - chunkOffset,
                clusterID: SpeakerLabel.namespaced(chunkID: run.id, rawLabel: $0.clusterID),
                quality: $0.quality
            )
        }

        guard let words = segment.words, !words.isEmpty else {
            // No word timings: the whole segment goes to whichever cluster it
            // overlaps most. Coarser, and the only option a backend that
            // reports segments alone leaves open.
            let (clusters, _) = SpeakerAlignment.assign(
                spans: [TimedSpan(start: segment.start, end: segment.end)], to: intervals
            )
            var labelled = segment
            labelled.speaker = clusters.first ?? nil
            return [labelled]
        }

        let spans = words.map { TimedSpan(start: $0.start, end: $0.end) }
        let (clusters, _) = SpeakerAlignment.assign(spans: spans, to: intervals)

        var pieces: [RawTranscriptSegment] = []
        var currentSpeaker: String?
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

    private func assembleTrack(
        _ chunks: [RawTranscriptChunk], treatAsLocalUser: Bool, echoReference: [Utterance]
    ) -> [Utterance] {
        var accepted: [Utterance] = []
        for chunk in chunks {
            let candidates = utterances(
                from: chunk, treatAsLocalUser: treatAsLocalUser, echoReference: echoReference
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
        from chunk: RawTranscriptChunk, treatAsLocalUser: Bool, echoReference: [Utterance]
    ) -> [Utterance] {
        var result: [Utterance] = []
        var current: (
            start: Double, end: Double, speaker: String?, text: String, words: [RawTranscriptWord]
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
                words: group.words.isEmpty ? nil : group.words.map {
                    RawTranscriptWord(
                        start: chunk.timelineOffset + $0.start,
                        end: chunk.timelineOffset + $0.end,
                        text: $0.text, probability: $0.probability
                    )
                }
            ))
            current = nil
        }

        for segment in chunk.segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if isEcho(text, start: chunk.timelineOffset + segment.start,
                      end: chunk.timelineOffset + segment.end, reference: echoReference) {
                continue
            }
            if var group = current,
               group.speaker == segment.speaker,
               segment.start - group.end <= configuration.utteranceGapSeconds,
               segment.end - group.start <= configuration.maxUtteranceSeconds {
                group.end = max(group.end, segment.end)
                group.text += group.text.isEmpty ? text : " \(text)"
                group.words += segment.words ?? []
                current = group
            } else {
                flush()
                current = (segment.start, segment.end, segment.speaker, text, segment.words ?? [])
            }
        }
        flush()
        return result
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
public struct TranscriptRenderer: Sendable {
    public init() {}

    public func markdown(
        transcript: CanonicalTranscript,
        speakers: SpeakerMap,
        title: String,
        startedAt: Date,
        durationSeconds: Double
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("\(startedAt.formatted(date: .long, time: .shortened)) · \(formatDuration(durationSeconds))")
        lines.append("")

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
