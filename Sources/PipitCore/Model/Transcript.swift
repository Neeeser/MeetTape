import Foundation

/// Exactly what the API returned for one chunk, stored unmodified.
///
/// Raw diarization is immutable. Renaming a speaker edits `speakers.map.json`, and
/// never this file, so a name change costs nothing and loses nothing.
/// Why a chunk was requested.
///
/// A cloud diarizer returns words as well as labels, and when it is also the
/// transcription backend those words are the transcript. When transcription
/// runs on this Mac they are a byproduct: the labels are wanted, the words are
/// already better locally, and assembling both would say everything twice.
public enum RawChunkPurpose: String, Codable, Sendable, Equatable {
    case words
    case speakers
}

public struct RawTranscriptChunk: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var track: CaptureTrack
    /// Where this chunk starts on the meeting timeline, in seconds.
    public var timelineOffset: Double
    public var durationSeconds: Double
    public var model: String
    public var responseFormat: String
    public var segments: [RawTranscriptSegment]
    /// The transcript of a chunk whose model returned no timings. The
    /// alignment stage reads it; every timed chunk leaves it nil and keeps the
    /// words in `segments`.
    public var text: String?
    /// The raw response body, kept so a future build can re-derive more from it.
    public var rawResponseFile: String?
    /// Defaulted, so a meeting written before this existed reads as what it was:
    /// every chunk on disk then held the transcript.
    public var purpose: RawChunkPurpose

    public init(
        id: String, track: CaptureTrack, timelineOffset: Double, durationSeconds: Double,
        model: String, responseFormat: String, segments: [RawTranscriptSegment],
        text: String? = nil, rawResponseFile: String? = nil, purpose: RawChunkPurpose = .words
    ) {
        self.id = id
        self.track = track
        self.timelineOffset = timelineOffset
        self.purpose = purpose
        self.durationSeconds = durationSeconds
        self.model = model
        self.responseFormat = responseFormat
        self.segments = segments
        self.text = text
        self.rawResponseFile = rawResponseFile
    }

    /// Hand-written so a chunk stored before `purpose` existed still decodes.
    /// Those files predate any diarizer that was not also the transcriber, so
    /// every one of their chunks held words.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        track = try container.decode(CaptureTrack.self, forKey: .track)
        timelineOffset = try container.decode(Double.self, forKey: .timelineOffset)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        model = try container.decode(String.self, forKey: .model)
        responseFormat = try container.decode(String.self, forKey: .responseFormat)
        segments = try container.decode([RawTranscriptSegment].self, forKey: .segments)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        rawResponseFile = try container.decodeIfPresent(String.self, forKey: .rawResponseFile)
        purpose = try container.decodeIfPresent(RawChunkPurpose.self, forKey: .purpose) ?? .words
    }
}

/// One word with its own timing.
///
/// Only a transcription backend that reports word timings fills these in. They
/// are what speaker attribution aligns against, which is why the local decoder
/// runs without prompt conditioning: prompting improves punctuation and
/// collapses word timings, and a 60-second clip went from 198 distinct word
/// starts to 153 with 43 words reporting zero duration.
public struct RawTranscriptWord: Codable, Sendable, Equatable {
    /// Chunk-relative start, in seconds.
    public var start: Double
    public var end: Double
    public var text: String
    /// The decoder's own probability for this token, kept for diagnostics.
    public var probability: Double?

    public init(start: Double, end: Double, text: String, probability: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.probability = probability
    }
}

public struct RawTranscriptSegment: Codable, Sendable, Equatable {
    /// Chunk-relative start, in seconds, exactly as returned.
    public var start: Double
    public var end: Double
    public var text: String
    /// The API's anonymous label, such as "A". Only meaningful inside its chunk.
    public var speaker: String?
    /// Present when the backend reported word timings. Absent for backends that
    /// return segments only, and absent in every file written before local
    /// transcription existed, which is why it decodes as optional.
    public var words: [RawTranscriptWord]?

    public init(
        start: Double, end: Double, text: String, speaker: String?,
        words: [RawTranscriptWord]? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
    }
}

/// Derived timings for one text-only chunk, stored beside the raw transcript.
///
/// The words are the transcription model's; the timings were forced against
/// the chunk's audio by the named aligner. Regenerable, so a better aligner
/// can rewrite it without touching what the model said.
public struct ChunkAlignment: Codable, Sendable, Equatable {
    /// Which aligner produced the timings, as provenance.
    public var aligner: String
    public var alignedAt: Date
    /// Chunk-relative, in the same shape a timed backend returns. Empty when
    /// the aligner refused.
    public var segments: [RawTranscriptSegment]
    /// The aligner found no path through this chunk. Recorded so the attempt
    /// is not repeated on every run, and so a later build can tell a refusal
    /// from real timings and try again. Decodes false for files written
    /// before it existed, which all carried timings.
    public var refused: Bool

    public init(
        aligner: String, alignedAt: Date, segments: [RawTranscriptSegment], refused: Bool = false
    ) {
        self.aligner = aligner
        self.alignedAt = alignedAt
        self.segments = segments
        self.refused = refused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aligner = try container.decode(String.self, forKey: .aligner)
        alignedAt = try container.decode(Date.self, forKey: .alignedAt)
        segments = try container.decode([RawTranscriptSegment].self, forKey: .segments)
        refused = try container.decodeIfPresent(Bool.self, forKey: .refused) ?? false
    }
}

public struct RawTranscript: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var chunks: [RawTranscriptChunk]

    public init(version: Int = RawTranscript.currentVersion, chunks: [RawTranscriptChunk] = []) {
        self.version = version
        self.chunks = chunks
    }

    public func chunks(track: CaptureTrack) -> [RawTranscriptChunk] {
        chunks.filter { $0.track == track }.sorted { $0.timelineOffset < $1.timelineOffset }
    }

    public func chunks(track: CaptureTrack, purpose: RawChunkPurpose) -> [RawTranscriptChunk] {
        chunks(track: track).filter { $0.purpose == purpose }
    }
}

/// Namespacing for anonymous diarization labels.
///
/// OpenAI's labels are only stable inside one request, so "A" in chunk 1 and "A"
/// in chunk 2 are not known to be the same person. Namespacing them keeps that
/// honest and leaves speaker resolution free to map several raw clusters onto one
/// participant.
public enum SpeakerLabel {
    public static let localUser = "local"
    /// Words no diarization interval claimed.
    ///
    /// They used to be filed under a fabricated cluster key, which renders the
    /// same as a real one: two rows both read "Speaker 1", naming one did not
    /// name the other, and the textual suggestion pass could put a real
    /// person's name on a scatter of stray backchannels. This key belongs to no
    /// run, has no occurrence row and no vector, so it reads as what it is.
    public static let unattributed = "unattributed"

    public static func namespaced(chunkID: String, rawLabel: String) -> String {
        // A label that already carries a namespace keeps it. Attribution against
        // a diarization run stamps the run into the key so a re-analysis cannot
        // inherit names that belonged to the previous clustering.
        if rawLabel.contains("_speaker_") { return rawLabel }
        return "\(chunkID)_speaker_\(normalise(rawLabel))"
    }

    /// A key for one track's unattributed words. Namespaced by track so the
    /// microphone's and the far end's do not merge into one row.
    public static func unattributed(track: CaptureTrack) -> String {
        "\(track.rawValue)_\(unattributed)"
    }

    public static func chunkID(index: Int) -> String {
        String(format: "chunk_%03d", index)
    }

    private static func normalise(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces).lowercased()
        if let numeric = Int(trimmed) { return String(format: "%02d", numeric) }
        if trimmed.hasPrefix("speaker_") { return String(trimmed.dropFirst("speaker_".count)) }
        // "S1", "S2": the offline diarizer's own cluster names, one-based.
        if trimmed.count >= 2, let first = trimmed.first, first.isLetter,
           let index = Int(trimmed.dropFirst()), index >= 1 {
            return String(format: "%02d", index - 1)
        }
        if trimmed.count == 1, let scalar = trimmed.unicodeScalars.first, scalar.properties.isAlphabetic {
            // "A" -> 00, "B" -> 01, matching the shape of numeric labels.
            let offset = Int(scalar.value) - Int(UnicodeScalar("a").value)
            return String(format: "%02d", offset)
        }
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }
}

/// One line of the canonical transcript.
public struct Utterance: Codable, Sendable, Equatable, Identifiable {
    /// Derived from where the line sits rather than from how many came before
    /// it.
    ///
    /// A positional identifier changes for every line after one that merges or
    /// splits, so re-assembling a transcript renumbered most of it. Nothing
    /// persisted is matched by this identifier, because corrections are anchored
    /// to a span on the timeline, but the review panel holds one between reading
    /// the transcript and the user clicking, and a renumbering in that window
    /// silently moved the click to a different line. Derived from the chunk, the
    /// track and the times, it either still names the same audio or does not
    /// exist, and the caller is told which.
    public var id: String
    /// Seconds from the start of the meeting timeline.
    public var start: Double
    public var end: Double
    public var track: CaptureTrack
    /// The namespaced raw diarization label, nil for the microphone track where
    /// the speaker is known by construction.
    public var rawSpeakerLabel: String?
    /// Stable identity used for display. Either `SpeakerLabel.localUser` or the raw
    /// label, resolved through the speaker map at render time.
    public var speakerKey: String
    public var text: String
    public var chunkID: String
    public var model: String
    /// The words behind the text, on the meeting timeline, where the backend
    /// reported timings.
    ///
    /// Carried through from the raw segments so a person can divide a line at a
    /// word and the piece keeps the audio it actually covers. Interpolating the
    /// division from character positions would be enough to render, and not
    /// enough to enrol: a correction is what writes a voice profile, and the
    /// span it hands to voice memory has to be the seconds that changed hands.
    /// Absent for a backend that reports no timings and for a transcript
    /// written before this existed, and a line without them is not divisible
    /// except at its edges.
    public var words: [RawTranscriptWord]?

    /// The identifier for a line covering this piece of a track.
    ///
    /// Milliseconds, because the timings a decoder reports are stable to far
    /// better than that and a floating-point rendering of them is not.
    public static func identifier(
        chunkID: String, track: CaptureTrack, start: Double, end: Double
    ) -> String {
        String(
            format: "%@-%@-%06d-%06d", chunkID, track.rawValue,
            Int((start * 1_000).rounded()), Int((end * 1_000).rounded())
        )
    }

    public init(
        id: String, start: Double, end: Double, track: CaptureTrack,
        rawSpeakerLabel: String?, speakerKey: String, text: String,
        chunkID: String, model: String, words: [RawTranscriptWord]? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.track = track
        self.rawSpeakerLabel = rawSpeakerLabel
        self.speakerKey = speakerKey
        self.text = text
        self.chunkID = chunkID
        self.model = model
        self.words = words
    }
}

/// `transcript.json`. Derived from the raw responses plus the timeline, and safe
/// to regenerate at any time.
public struct CanonicalTranscript: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var utterances: [Utterance]

    public init(version: Int = CanonicalTranscript.currentVersion, generatedAt: Date, utterances: [Utterance]) {
        self.version = version
        self.generatedAt = generatedAt
        self.utterances = utterances
    }

    public var durationSeconds: Double { utterances.map(\.end).max() ?? 0 }

    public var speakerKeys: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for utterance in utterances where !seen.contains(utterance.speakerKey) {
            seen.insert(utterance.speakerKey)
            ordered.append(utterance.speakerKey)
        }
        return ordered
    }
}
