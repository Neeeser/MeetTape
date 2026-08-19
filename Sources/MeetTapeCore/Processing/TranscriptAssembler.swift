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
            let chunks = raw.chunks(track: track)
            guard !chunks.isEmpty else { continue }
            let treatAsLocalUser = track == .mic && micTrackIsLocalUser
            // Sorted so the echo scan can stop at the first utterance past its
            // window instead of walking the whole meeting per segment.
            let assembled = assembleTrack(
                chunks,
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
                accepted.append(candidate)
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
        var current: (start: Double, end: Double, speaker: String?, text: String)?

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
                : (rawLabel ?? SpeakerLabel.namespaced(chunkID: chunk.id, rawLabel: "00"))
            result.append(Utterance(
                id: "\(chunk.id)-\(result.count)",
                start: chunk.timelineOffset + group.start,
                end: chunk.timelineOffset + group.end,
                track: chunk.track,
                rawSpeakerLabel: treatAsLocalUser ? nil : rawLabel,
                speakerKey: speakerKey,
                text: group.text.trimmingCharacters(in: .whitespaces),
                chunkID: chunk.id,
                model: chunk.model
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
                current = group
            } else {
                flush()
                current = (segment.start, segment.end, segment.speaker, text)
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
            let name = speakers.resolvedName(for: utterance.speakerKey)
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
            "[\(timecode(utterance.start))] \(speakers.resolvedName(for: utterance.speakerKey)): \(utterance.text)"
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
